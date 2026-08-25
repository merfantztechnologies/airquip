/**
 * Fixed QB → SF Vendor sync (replacement for packaged faxa.QuickBooksVendorFromQBSyncBatch).
 *
 * Root cause of "Too many SOQL queries: 201" in the package batch:
 *   1) Up to 1000 Vendors processed in a single execute
 *   2) Per-Vendor tax SOQL (findTaxRecordSfIdByQbTaxCodeId)
 *   3) Per-matched-Account name-duplicate SOQL (resolvePreferredVendorAccountForUpdate)
 *   4) Account triggers amplify SOQL on large DML sets
 *
 * Fixes applied here:
 *   - Small QB page size (50) + chained continuation jobs (callouts before DML)
 *   - Tax codes preloaded once in start() (Map lookup, no per-row SOQL)
 *   - Bulk Account match by QB Vendor Id then Name (no N+1 SOQL)
 *   - Governor pre-flight before each page
 *
 * Usage:
 *   Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(), 1);
 *   System.schedule('QB Vendor Sync Fixed', '0 0 6 * * ?', new QuickBooksVendorFromQBSyncBatchFixed());
 *
 * Disable / unschedule the packaged QuickBooksVendorFromQBSyncBatch job when using this class.
 */
public class QuickBooksVendorFromQBSyncBatchFixed
    implements Database.Batchable<String>, Database.Stateful, Database.AllowsCallouts, Schedulable {

    /** Keep low so Account triggers + matching stay under 200 SOQL. */
    private static final Integer QB_QUERY_PAGE_SIZE = 50;
    private static final Integer MAX_CONTINUATION_PAGE = 500;
    private static final String APP_NAME = 'QuickBook';
    private static final String FULL_SYNC_SCOPE = 'FULL_SYNC';
    private static final String TOKEN_ENDPOINT = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';
    /** faxa__External_App_Request__c.faxa__Response__c is typically Long Text Area (32,768). */
    private static final Integer MAX_RESPONSE_LENGTH = 32768;
    private static final Integer PAGE_SOQL_RESERVE = 80;
    private static final Integer PAGE_DML_RESERVE = 20;
    private static final Integer PAGE_CPU_RESERVE_MS = 15000;

    private String realmId;
    private String accessToken;
    private String refreshToken;
    private String clientId;
    private String clientSecret;
    private Id externalAppId;
    private Boolean isSandbox;

    private List<faxa__Mapping__c> mappings;
    private Map<String, Id> taxCodeMap;
    private faxa__External_App__c pendingTokenUpdate;

    private Integer startAtPage = 1;
    private Integer pendingContinuationPage;
    private Integer totalProcessed = 0;
    private Integer totalUpdated = 0;
    private Integer totalInserted = 0;
    private List<String> errors = new List<String>();

    public QuickBooksVendorFromQBSyncBatchFixed() {
        this.isSandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }

    public QuickBooksVendorFromQBSyncBatchFixed(Boolean isSandbox) {
        this.isSandbox = isSandbox;
    }

    /** Continuation — resume full sync at a specific QB query page. */
    public QuickBooksVendorFromQBSyncBatchFixed(Integer startAtPageNumber) {
        this.isSandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
        this.startAtPage = (startAtPageNumber != null && startAtPageNumber > 0) ? startAtPageNumber : 1;
    }

    public QuickBooksVendorFromQBSyncBatchFixed(Integer startAtPageNumber, Boolean isSandbox) {
        this.isSandbox = isSandbox;
        this.startAtPage = (startAtPageNumber != null && startAtPageNumber > 0) ? startAtPageNumber : 1;
    }

    // ─── Batchable ────────────────────────────────────────────────────────────

    public Iterable<String> start(Database.BatchableContext bc) {
        faxa__External_App__c app = [
            SELECT Id, faxa__Realm_ID__c, faxa__Access_Token__c,
                   faxa__Refresh_Token__c, faxa__Client_Id__c,
                   faxa__Client_Secret__c, faxa__Authentication_Status__c
            FROM faxa__External_App__c
            WHERE Name = :APP_NAME
            LIMIT 1
        ];

        if (app == null || app.faxa__Authentication_Status__c != 'Successful') {
            throw new BatchException('QuickBook External App not found or not authenticated.');
        }
        if (String.isBlank(app.faxa__Realm_ID__c) || String.isBlank(app.faxa__Access_Token__c)) {
            throw new BatchException('QuickBook Realm ID or Access Token is missing.');
        }

        realmId = app.faxa__Realm_ID__c;
        accessToken = app.faxa__Access_Token__c;
        refreshToken = app.faxa__Refresh_Token__c;
        clientId = app.faxa__Client_Id__c;
        clientSecret = app.faxa__Client_Secret__c;
        externalAppId = app.Id;

        mappings = [
            SELECT faxa__FieldAx_Field__c, faxa__External_App_Field__c, faxa__External_Object__c
            FROM faxa__Mapping__c
            WHERE faxa__FieldAx_Object__c = 'Account'
            AND faxa__External_App__c = :externalAppId
            AND (faxa__External_Object__c = 'Vendor'
                 OR faxa__External_Object__c = 'vendor'
                 OR faxa__External_Object__c = null
                 OR faxa__External_Object__c = '')
            ORDER BY faxa__Sequence__c NULLS LAST
        ];

        // Prefer Vendor-specific rows when both null and Vendor exist
        List<faxa__Mapping__c> vendorOnly = new List<faxa__Mapping__c>();
        for (faxa__Mapping__c m : mappings) {
            if (m.faxa__External_Object__c != null
                && m.faxa__External_Object__c.trim().equalsIgnoreCase('Vendor')) {
                vendorOnly.add(m);
            }
        }
        if (!vendorOnly.isEmpty()) {
            mappings = vendorOnly;
        }

        // FIX: preload all tax codes once (package did per-Vendor SOQL)
        taxCodeMap = new Map<String, Id>();
        for (faxa__Tax__c t : [
            SELECT Id, faxa__Tax_Code_Id__c
            FROM faxa__Tax__c
            WHERE faxa__Tax_Code_Id__c != null
        ]) {
            String key = normalizeQbId(t.faxa__Tax_Code_Id__c);
            if (String.isNotBlank(key)) {
                taxCodeMap.put(key, t.Id);
            }
        }

        return new List<String>{ FULL_SYNC_SCOPE };
    }

    public void execute(Database.BatchableContext bc, List<String> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }

        Integer pageIndex = (startAtPage != null && startAtPage > 0) ? startAtPage : 1;

        if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
            errors.add('Paused at page ' + pageIndex + ': HTTP callout limit reached.');
            queueContinuation(pageIndex);
            return;
        }
        if (isLowOnBudget()) {
            errors.add(
                'Paused before page ' + pageIndex +
                ' (SOQL=' + Limits.getQueries() + '/' + Limits.getLimitQueries() +
                ', DML=' + Limits.getDmlStatements() + '/' + Limits.getLimitDmlStatements() + ').'
            );
            queueContinuation(pageIndex);
            return;
        }

        Boolean mayHaveMore = processVendorPage(pageIndex);
        if (mayHaveMore) {
            queueContinuation(pageIndex + 1);
        }
    }

    public void finish(Database.BatchableContext bc) {
        if (pendingTokenUpdate != null && pendingTokenUpdate.Id != null) {
            try {
                update pendingTokenUpdate;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'QuickBooksVendorFromQBSyncBatchFixed: token save failed: ' + e.getMessage());
            }
        }

        System.debug(
            'QuickBooksVendorFromQBSyncBatchFixed finished. Processed=' + totalProcessed +
            ', Updated=' + totalUpdated + ', Inserted=' + totalInserted
        );
        if (!errors.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'Errors: ' + String.join(errors, '; '));
        }

        if (pendingContinuationPage != null) {
            if (pendingContinuationPage > MAX_CONTINUATION_PAGE) {
                System.debug(LoggingLevel.ERROR,
                    'Vendor sync stopped at max page ' + MAX_CONTINUATION_PAGE);
                return;
            }
            Database.executeBatch(
                new QuickBooksVendorFromQBSyncBatchFixed(pendingContinuationPage, isSandbox),
                1
            );
        }
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(), 1);
    }

    // ─── Page processing ──────────────────────────────────────────────────────

    private Boolean processVendorPage(Integer pageIndex) {
        Integer startPosition = (pageIndex - 1) * QB_QUERY_PAGE_SIZE + 1;
        String baseUrl = isSandbox
            ? 'https://sandbox-quickbooks.api.intuit.com'
            : 'https://quickbooks.api.intuit.com';

        // Added "where Active = true" before the orderby clause
String query = 'select * from Vendor where Active = true orderby MetaData.LastUpdatedTime desc startposition '
    + startPosition + ' maxresults ' + QB_QUERY_PAGE_SIZE;
        String endpoint = baseUrl + '/v3/company/' + realmId + '/query?query='
            + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpResponse res = callQB(endpoint);
        String body = (res != null) ? res.getBody() : null;
        String truncated = truncate(body);

        faxa__External_App_Request__c req = new faxa__External_App_Request__c(
            faxa__External_App__c = externalAppId,
            faxa__Object_Name__c = 'Account',
            faxa__Request_End_Point__c = endpoint,
            faxa__Request_Method__c = 'GET',
            faxa__Response__c = truncated
        );

        if (res == null || res.getStatusCode() != 200) {
            Integer code = (res != null) ? res.getStatusCode() : 0;
            String errMsg = 'Page ' + pageIndex + ': QB API ' + code;
            errors.add(errMsg);
            insertRequestSafe(req);
            insert new faxa__External_App_Request_Log__c(
                faxa__QB_Http_Request__c = req.Id,
                faxa__Status__c = ('Failed: QB API ' + code).left(255),
                faxa__Error_Message__c = errMsg
            );
            return false;
        }

        if (String.isBlank(body)) {
            insertRequestSafe(req);
            insert new faxa__External_App_Request_Log__c(
                faxa__QB_Http_Request__c = req.Id,
                faxa__Status__c = 'Failed: Empty response'
            );
            return false;
        }

        Map<String, Object> root;
        try {
            root = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (JSONException e) {
            errors.add('Page ' + pageIndex + ': Invalid JSON - ' + e.getMessage());
            insertRequestSafe(req);
            insert new faxa__External_App_Request_Log__c(
                faxa__QB_Http_Request__c = req.Id,
                faxa__Status__c = 'Failed: Invalid JSON',
                faxa__Error_Message__c = e.getMessage()
            );
            return false;
        }

        Map<String, Object> qr = (Map<String, Object>) root.get('QueryResponse');
        List<Object> vendors = parseVendorList(qr);
        Boolean fullPage = vendors.size() == QB_QUERY_PAGE_SIZE;

        if (vendors.isEmpty()) {
            insertRequestSafe(req);
            insert new faxa__External_App_Request_Log__c(
                faxa__QB_Http_Request__c = req.Id,
                faxa__Status__c = ('Success: Page ' + pageIndex + ' - 0 vendors').left(255)
            );
            return false;
        }

        List<Account> mapped = new List<Account>();
        for (Object v : vendors) {
            Account acc = mapVendor((Map<String, Object>) v);
            if (acc != null) {
                mapped.add(acc);
            }
        }

        insertRequestSafe(req);

        if (!mapped.isEmpty()) {
            matchAndUpsert(mapped);
        }

        String status = 'Success: Page ' + pageIndex + ' - JSON ' + vendors.size()
            + ', mapped ' + mapped.size()
            + '; upd ' + totalUpdated + ', ins ' + totalInserted;
        if (!errors.isEmpty()) {
            status += '; err ' + errors[errors.size() - 1];
        }
        insert new faxa__External_App_Request_Log__c(
            faxa__QB_Http_Request__c = req.Id,
            faxa__Status__c = status.left(255)
        );

        return fullPage;
    }

    // ─── Bulk match & DML (no N+1 SOQL) ───────────────────────────────────────

    private void matchAndUpsert(List<Account> toUpsert) {
        if (toUpsert == null || toUpsert.isEmpty()) {
            return;
        }
        totalProcessed += toUpsert.size();

        Set<String> qbIds = new Set<String>();
        Set<String> names = new Set<String>();
        for (Account a : toUpsert) {
            String qbId = normalizeQbId(a.get('faxa__QuickBooks_Vendor_Id__c'));
            if (String.isNotBlank(qbId)) {
                qbIds.add(qbId);
            }
            if (String.isNotBlank(a.Name)) {
                names.add(a.Name.trim());
            }
        }

        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
        Set<String> queryFields = new Set<String>{
            'Id', 'Name', 'faxa__QuickBooks_Vendor_Id__c', 'faxa__Account_Type__c'
        };
        for (faxa__Mapping__c m : mappings) {
            String sf = m.faxa__FieldAx_Field__c;
            if (sf == null) {
                continue;
            }
            Schema.SObjectField ft = fieldMap.get(sf.toLowerCase());
            if (ft != null && ft.getDescribe().isUpdateable()) {
                queryFields.add(sf);
            }
        }
        for (String addr : new List<String>{
            'BillingStreet', 'BillingCity', 'BillingState', 'BillingPostalCode', 'BillingCountry',
            'BillingStateCode', 'BillingCountryCode',
            'ShippingStreet', 'ShippingCity', 'ShippingState', 'ShippingPostalCode', 'ShippingCountry',
            'ShippingStateCode', 'ShippingCountryCode', 'Phone'
        }) {
            if (fieldMap.containsKey(addr.toLowerCase())) {
                queryFields.add(addr);
            }
        }

        String fieldList = String.join(new List<String>(queryFields), ', ');

        // 1) Match by QB Vendor Id — single SOQL
        Map<String, Account> byQbId = new Map<String, Account>();
        if (!qbIds.isEmpty()) {
            for (Account ex : Database.query(
                'SELECT ' + fieldList + ' FROM Account WHERE faxa__QuickBooks_Vendor_Id__c IN :qbIds'
            )) {
                String key = normalizeQbId(ex.get('faxa__QuickBooks_Vendor_Id__c'));
                if (String.isNotBlank(key) && !byQbId.containsKey(key)) {
                    byQbId.put(key, ex);
                }
            }
        }

        // 2) Name match only where Vendor Id is blank — single SOQL
        Map<String, Account> byName = new Map<String, Account>();
        if (!names.isEmpty()) {
            List<String> nameList = new List<String>(names);
           for (Account ex : Database.query(
                    'SELECT ' + fieldList + ' FROM Account WHERE Name IN :nameList'
                    + ' AND (faxa__QuickBooks_Vendor_Id__c = null OR faxa__QuickBooks_Vendor_Id__c = \'\')'
                    + ' AND (faxa__QuickBooks_Customer_Id__c = null OR faxa__QuickBooks_Customer_Id__c = \'\')'
                    + ' ORDER BY CreatedDate ASC'
                )) {
                String nk = nameKey(ex.Name);
                if (String.isNotBlank(nk) && !byName.containsKey(nk)) {
                    byName.put(nk, ex);
                }
            }
        }

        List<Account> toInsert = new List<Account>();
        Map<Id, Account> toUpdateMap = new Map<Id, Account>();
        Set<Id> matchedIds = new Set<Id>();

        for (Account staged : toUpsert) {
            String qbId = normalizeQbId(staged.get('faxa__QuickBooks_Vendor_Id__c'));
            Account match = String.isNotBlank(qbId) ? byQbId.get(qbId) : null;
            if (match == null && String.isNotBlank(staged.Name)) {
                match = byName.get(nameKey(staged.Name));
            }

            if (match != null) {
                if (matchedIds.contains(match.Id)) {
                    continue;
                }
                matchedIds.add(match.Id);

                Account upd = new Account(Id = match.Id);
                upd.put('faxa__QuickBooks_Vendor_Id__c', qbId);
                if (fieldMap.containsKey('faxa__account_type__c')) {
                    upd.put('faxa__Account_Type__c', 'Vendor');
                }

                Map<String, Object> newFields = staged.getPopulatedFieldsAsMap();
                for (String fld : newFields.keySet()) {
                    if (fld.equalsIgnoreCase('Id') || fld.equalsIgnoreCase('faxa__QuickBooks_Vendor_Id__c')) {
                        continue;
                    }
                    Object newVal = newFields.get(fld);
                    if (newVal == null) {
                        continue;
                    }
                    upd.put(fld, newVal);
                }
                toUpdateMap.put(match.Id, upd);
            } else {
                toInsert.add(staged);
            }
        }

        Database.DMLOptions dmlOpts = new Database.DMLOptions();
        dmlOpts.DuplicateRuleHeader.allowSave = true;
        dmlOpts.optAllOrNone = false;

        if (!toUpdateMap.isEmpty()) {
            List<Account> toUpdate = toUpdateMap.values();
            for (Database.SaveResult sr : Database.update(toUpdate, false)) {
                if (sr.isSuccess()) {
                    totalUpdated++;
                } else {
                    for (Database.Error e : sr.getErrors()) {
                        errors.add('Update: ' + e.getMessage());
                    }
                }
            }
        }

        if (!toInsert.isEmpty()) {
            for (Database.SaveResult sr : Database.insert(toInsert, dmlOpts)) {
                if (sr.isSuccess()) {
                    totalInserted++;
                } else {
                    for (Database.Error e : sr.getErrors()) {
                        errors.add('Insert: ' + e.getMessage());
                    }
                }
            }
        }
    }

    // ─── Mapping ──────────────────────────────────────────────────────────────

    private Account mapVendor(Map<String, Object> qb) {
        if (qb == null) {
            return null;
        }
        Object idObj = qb.get('Id');
        if (idObj == null) {
            idObj = qb.get('id');
        }
        String qbId = normalizeQbId(idObj);
        if (String.isBlank(qbId)) {
            return null;
        }

        Account acc = new Account();
        acc.put('faxa__QuickBooks_Vendor_Id__c', qbId);

        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
        if (fieldMap.containsKey('faxa__account_type__c')) {
            acc.put('faxa__Account_Type__c', 'Vendor');
        }

        if (mappings != null) {
            for (faxa__Mapping__c m : mappings) {
                String sfField = m.faxa__FieldAx_Field__c;
                String qbPath = m.faxa__External_App_Field__c;
                if (String.isBlank(sfField) || String.isBlank(qbPath)) {
                    continue;
                }
                if (sfField.contains(',')) {
                    sfField = sfField.split(',')[0].trim();
                }
                if (sfField.equalsIgnoreCase('faxa__QuickBooks_Vendor_Id__c')
                    || sfField.equalsIgnoreCase('faxa__QuickBooks_Customer_Id__c')) {
                    continue;
                }

                Schema.SObjectField fieldToken = fieldMap.get(sfField.toLowerCase());
                if (fieldToken == null) {
                    continue;
                }
                Schema.DescribeFieldResult dfr = fieldToken.getDescribe();

                Object val = getNested(qb, qbPath);
                if (val == null && isTaxCodePath(qbPath)) {
                    val = getNested(qb, 'DefaultTaxCodeRef.value');
                }
                // Vendor JSON uses TermRef; mappings often still point at SalesTermRef (Customer path).
                if (val == null && isTermRefPath(qbPath)) {
                    val = getNested(qb, aliasSalesTermPathToVendorTermPath(qbPath));
                }
                // Prefer term name for Terms picklist even when mapping targets .value
                if (isTermsLikeField(sfField) && isTermRefPath(qbPath)) {
                    Object termName = resolveQbTermDisplayName(qb);
                    if (termName != null) {
                        val = termName;
                    }
                }

                // Formula tax-code id → writable tax lookup
                if (!dfr.isUpdateable()) {
                    if (isTaxCodeRelatedField(sfField) && val != null) {
                        Id taxId = taxCodeMap.get(normalizeQbId(val));
                        if (taxId != null) {
                            putTaxLookup(acc, fieldMap, taxId);
                        }
                    }
                    continue;
                }

                if (val == null) {
                    continue;
                }

                try {
                    if (dfr.getType() == Schema.DisplayType.REFERENCE) {
                        List<Schema.SObjectType> refs = dfr.getReferenceTo();
                        if (refs != null) {
                            for (Schema.SObjectType rt : refs) {
                                String rel = rt != null ? rt.getDescribe().getName() : null;
                                if (rel != null && rel.toLowerCase().contains('tax')) {
                                    Id taxId = taxCodeMap.get(normalizeQbId(val));
                                    if (taxId != null) {
                                        acc.put(sfField, taxId);
                                    }
                                    break;
                                }
                            }
                        }
                        continue;
                    }

                    String strVal = unwrapScalar(val);
                    if (String.isBlank(strVal)) {
                        continue;
                    }
                    String sfLower = sfField.toLowerCase();
                    if (sfLower == 'billingcountry' || sfLower == 'shippingcountry') {
                        String code = normalizeCountryCode(strVal);
                        if (code != null && fieldMap.containsKey(sfLower + 'code')) {
                            acc.put(sfLower == 'billingcountry' ? 'BillingCountryCode' : 'ShippingCountryCode', code);
                        }
                        continue;
                    }
                    if (sfLower == 'billingstate' || sfLower == 'shippingstate') {
                        // Prefer state code when org uses state/country picklists
                        if (fieldMap.containsKey(sfLower + 'code') && strVal.length() <= 3) {
                            acc.put(sfLower == 'billingstate' ? 'BillingStateCode' : 'ShippingStateCode', strVal.toUpperCase());
                            continue;
                        }
                    }
                    if (dfr.getType() == Schema.DisplayType.PICKLIST) {
                        // Prefer Ref.name when mapping was to .value
                        String pathLower = qbPath != null ? qbPath.toLowerCase() : '';
                        if (pathLower.endsWith('.value')) {
                            String namePath = qbPath.substring(0, qbPath.length() - '.value'.length()) + '.name';
                            Object nameVal = getNested(qb, namePath);
                            if (nameVal == null && isTermRefPath(qbPath)) {
                                nameVal = getNested(qb, aliasSalesTermPathToVendorTermPath(namePath));
                            }
                            if (nameVal != null) {
                                strVal = unwrapScalar(nameVal);
                            }
                        }
                        tryPutPicklistValue(acc, sfField, dfr, strVal);
                        continue;
                    }
                    if (dfr.getType() == Schema.DisplayType.PHONE && strVal.length() > 40) {
                        strVal = strVal.left(40);
                    }
                    if (dfr.getType() == Schema.DisplayType.STRING
                        || dfr.getType() == Schema.DisplayType.TEXTAREA) {
                        Integer maxLen = dfr.getLength();
                        if (maxLen != null && maxLen > 0 && strVal.length() > maxLen) {
                            strVal = strVal.left(maxLen);
                        }
                    }
                    if ('name'.equalsIgnoreCase(sfField)) {
                        strVal = collapseWhitespace(strVal);
                    }
                    acc.put(sfField, strVal);
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN,
                        'Vendor mapping skip ' + sfField + ': ' + e.getMessage());
                }
            }
        }

        if (String.isBlank(acc.Name)) {
            String display = resolveDisplayName(qb);
            acc.Name = String.isNotBlank(display) ? display : ('QB-Vendor-' + qbId);
        }

        // Always fill/backfill BillAddr so orgs with "all billing address fields required" still save.
        applyBillAddrFromQb(acc, qb);
        applyShipAddrFromQbOrBilling(acc, qb);
        ensureAddressForDml(acc);
        // Ensure Terms sync even when mapping path is SalesTermRef.* on Vendor JSON (TermRef).
        applyTermsFromQb(acc, qb, fieldMap);

        if (mappings == null || mappings.isEmpty()) {
            applyDefaultMapping(acc, qb, qbId);
        }

        return acc;
    }

    /** Apply Terms__c from QB TermRef / SalesTermRef name (picklist-safe). */
    private static void applyTermsFromQb(
        Account acc,
        Map<String, Object> qb,
        Map<String, Schema.SObjectField> fieldMap
    ) {
        if (acc == null || qb == null || fieldMap == null || !fieldMap.containsKey('terms__c')) {
            return;
        }
        Schema.DescribeFieldResult dfr = fieldMap.get('terms__c').getDescribe();
        if (!dfr.isCreateable() && !dfr.isUpdateable()) {
            return;
        }
        Object existing = acc.get('Terms__c');
        if (existing != null && String.isNotBlank(String.valueOf(existing))) {
            return;
        }
        String termName = resolveQbTermDisplayName(qb);
        if (String.isBlank(termName)) {
            return;
        }
        tryPutPicklistValue(acc, 'Terms__c', dfr, termName);
    }

    private static String resolveQbTermDisplayName(Map<String, Object> qb) {
        for (String path : new List<String>{
            'TermRef.name',
            'SalesTermRef.name',
            'TermRef',
            'SalesTermRef'
        }) {
            Object raw = getNested(qb, path);
            Object scalar = unwrapScalar(raw);
            if (scalar == null) {
                continue;
            }
            // Skip bare numeric Ids — picklist needs the term name
            String s = String.valueOf(scalar).trim();
            if (String.isBlank(s) || s.isNumeric()) {
                continue;
            }
            return s;
        }
        return null;
    }

    private static Boolean isTermRefPath(String qbPath) {
        if (String.isBlank(qbPath)) {
            return false;
        }
        String p = qbPath.trim().toLowerCase();
        return p.startsWith('salestermref') || p.startsWith('termref');
    }

    private static Boolean isTermsLikeField(String sfField) {
        if (String.isBlank(sfField)) {
            return false;
        }
        String lower = sfField.trim().toLowerCase();
        return lower == 'terms__c' || lower.contains('term');
    }

    /** Map SalesTermRef.* → TermRef.* for Vendor entities. */
    private static String aliasSalesTermPathToVendorTermPath(String qbPath) {
        if (String.isBlank(qbPath)) {
            return qbPath;
        }
        if (qbPath.length() >= 12 && qbPath.substring(0, 12).equalsIgnoreCase('SalesTermRef')) {
            return 'TermRef' + qbPath.substring(12);
        }
        if (qbPath.length() >= 7 && qbPath.substring(0, 7).equalsIgnoreCase('TermRef')) {
            return 'SalesTermRef' + qbPath.substring(7);
        }
        return qbPath;
    }

    private static Boolean tryPutPicklistValue(
        Account acc,
        String fieldName,
        Schema.DescribeFieldResult d,
        String raw
    ) {
        if (acc == null || String.isBlank(fieldName) || d == null || String.isBlank(raw)) {
            return false;
        }
        String want = raw.trim();
        List<Schema.PicklistEntry> entries = d.getPicklistValues();
        if (entries == null || entries.isEmpty()) {
            return false;
        }
        for (Schema.PicklistEntry pe : entries) {
            if (pe == null || !pe.isActive()) {
                continue;
            }
            String api = pe.getValue();
            if (api != null && api.equalsIgnoreCase(want)) {
                acc.put(fieldName, api);
                return true;
            }
            String lab = pe.getLabel();
            if (lab != null && lab.equalsIgnoreCase(want)) {
                acc.put(fieldName, api);
                return true;
            }
        }
        // Soft match: collapse spaces / common QB variants like "Net 10" vs "NET 10"
        String wantNorm = want.replace(' ', '').toLowerCase();
        for (Schema.PicklistEntry pe : entries) {
            if (pe == null || !pe.isActive()) {
                continue;
            }
            String api = pe.getValue();
            if (api != null && api.replace(' ', '').equalsIgnoreCase(wantNorm)) {
                acc.put(fieldName, api);
                return true;
            }
            String lab = pe.getLabel();
            if (lab != null && lab.replace(' ', '').equalsIgnoreCase(wantNorm)) {
                acc.put(fieldName, api);
                return true;
            }
        }
        System.debug(LoggingLevel.WARN,
            'QuickBooksVendorFromQBSyncBatchFixed: no Terms picklist match for "' + want + '"');
        return false;
    }

    /**
     * When state/country picklists are enabled, free-text State/Country must not be set
     * alongside StateCode/CountryCode (causes "Mismatched integration value and ISO code").
     */
    private static void clearConflictingAddressTextFields(Account acc) {
        if (acc == null) {
            return;
        }
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Account.fields.getMap();
        if (fm.containsKey('billingstatecode') && acc.get('BillingStateCode') != null) {
            acc.BillingState = null;
        }
        if (fm.containsKey('billingcountrycode') && acc.get('BillingCountryCode') != null) {
            acc.BillingCountry = null;
        }
        if (fm.containsKey('shippingstatecode') && acc.get('ShippingStateCode') != null) {
            acc.ShippingState = null;
        }
        if (fm.containsKey('shippingcountrycode') && acc.get('ShippingCountryCode') != null) {
            acc.ShippingCountry = null;
        }
    }

    /** Overlay BillAddr onto Account when target fields are blank (validation-safe). */
    private static void applyBillAddrFromQb(Account acc, Map<String, Object> qb) {
        if (acc == null || qb == null) {
            return;
        }
        if (String.isBlank(acc.BillingStreet)) {
            Object v = getNested(qb, 'BillAddr.Line1');
            if (v != null) {
                acc.BillingStreet = String.valueOf(v).left(255);
            }
        }
        if (String.isBlank(acc.BillingCity)) {
            Object v = getNested(qb, 'BillAddr.City');
            if (v != null) {
                acc.BillingCity = String.valueOf(v).left(40);
            }
        }
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Account.fields.getMap();
        Object stateRaw = getNested(qb, 'BillAddr.CountrySubDivisionCode');
        if (stateRaw != null) {
            String stateVal = String.valueOf(stateRaw).trim();
            if (fm.containsKey('billingstatecode') && stateVal.length() <= 3 && acc.get('BillingStateCode') == null) {
                acc.put('BillingStateCode', stateVal.toUpperCase());
            } else if (String.isBlank(acc.BillingState)) {
                acc.BillingState = stateVal.left(80);
            }
        }
        // Mapping may have set BillingState="TX"; convert to StateCode for picklist orgs
        if (fm.containsKey('billingstatecode')
            && String.isNotBlank(acc.BillingState)
            && acc.BillingState.trim().length() <= 3) {
            if (acc.get('BillingStateCode') == null) {
                acc.put('BillingStateCode', acc.BillingState.trim().toUpperCase());
            }
            acc.BillingState = null;
        }
        if (String.isBlank(acc.BillingPostalCode)) {
            Object v = getNested(qb, 'BillAddr.PostalCode');
            if (v != null) {
                acc.BillingPostalCode = String.valueOf(v).left(20);
            }
        }
        // State/Country picklists: set ISO code, never free-text "US" into BillingCountry
        Object countryRaw = getNested(qb, 'BillAddr.Country');
        if (countryRaw != null && fm.containsKey('billingcountrycode')) {
            String code = normalizeCountryCode(String.valueOf(countryRaw));
            if (code != null && acc.get('BillingCountryCode') == null) {
                acc.put('BillingCountryCode', code);
            }
        } else if (String.isBlank(acc.BillingCountry) && countryRaw != null) {
            acc.BillingCountry = String.valueOf(countryRaw).left(80);
        }
    }

    /** Fill ShipAddr from QB, or copy billing → shipping when shipping is blank (common validation rule). */
    private static void applyShipAddrFromQbOrBilling(Account acc, Map<String, Object> qb) {
        if (acc == null) {
            return;
        }
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Account.fields.getMap();

        Object line1 = getNested(qb, 'ShipAddr.Line1');
        Object city = getNested(qb, 'ShipAddr.City');
        Object state = getNested(qb, 'ShipAddr.CountrySubDivisionCode');
        Object postal = getNested(qb, 'ShipAddr.PostalCode');
        Object country = getNested(qb, 'ShipAddr.Country');
        Boolean hasShip = line1 != null || city != null || state != null || postal != null || country != null;

        if (hasShip) {
            if (String.isBlank(acc.ShippingStreet) && line1 != null) {
                acc.ShippingStreet = String.valueOf(line1).left(255);
            }
            if (String.isBlank(acc.ShippingCity) && city != null) {
                acc.ShippingCity = String.valueOf(city).left(40);
            }
            if (postal != null && String.isBlank(acc.ShippingPostalCode)) {
                acc.ShippingPostalCode = String.valueOf(postal).left(20);
            }
            if (state != null) {
                String stateVal = String.valueOf(state).trim();
                if (fm.containsKey('shippingstatecode') && stateVal.length() <= 3) {
                    if (acc.get('ShippingStateCode') == null) {
                        acc.put('ShippingStateCode', stateVal.toUpperCase());
                    }
                } else if (String.isBlank(acc.ShippingState)) {
                    acc.ShippingState = stateVal.left(80);
                }
            }
            if (country != null && fm.containsKey('shippingcountrycode')) {
                String code = normalizeCountryCode(String.valueOf(country));
                if (code != null && acc.get('ShippingCountryCode') == null) {
                    acc.put('ShippingCountryCode', code);
                }
            } else if (country != null && String.isBlank(acc.ShippingCountry)) {
                acc.ShippingCountry = String.valueOf(country).left(80);
            }
        }

        // Copy billing → shipping when shipping still incomplete
        if (String.isBlank(acc.ShippingStreet) && String.isNotBlank(acc.BillingStreet)) {
            acc.ShippingStreet = acc.BillingStreet;
        }
        if (String.isBlank(acc.ShippingCity) && String.isNotBlank(acc.BillingCity)) {
            acc.ShippingCity = acc.BillingCity;
        }
        if (String.isBlank(acc.ShippingPostalCode) && String.isNotBlank(acc.BillingPostalCode)) {
            acc.ShippingPostalCode = acc.BillingPostalCode;
        }
        if (fm.containsKey('shippingstatecode') && acc.get('ShippingStateCode') == null && acc.get('BillingStateCode') != null) {
            acc.put('ShippingStateCode', acc.get('BillingStateCode'));
        } else if (String.isBlank(acc.ShippingState) && String.isNotBlank(acc.BillingState)) {
            acc.ShippingState = acc.BillingState;
        }
        if (fm.containsKey('shippingcountrycode') && acc.get('ShippingCountryCode') == null && acc.get('BillingCountryCode') != null) {
            acc.put('ShippingCountryCode', acc.get('BillingCountryCode'));
        } else if (String.isBlank(acc.ShippingCountry) && String.isNotBlank(acc.BillingCountry)) {
            acc.ShippingCountry = acc.BillingCountry;
        }
    }

    private static String normalizeCountryCode(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String key = raw.trim().toUpperCase();
        if (key == 'US' || key == 'USA' || key == 'UNITED STATES' || key == 'UNITED STATES OF AMERICA') {
            return 'US';
        }
        // Tolerate QB typos e.g. "Unitd States", "Untied States", "United Staes"
        String letters = key.replaceAll('[^A-Z]', '');
        if (letters.startsWith('UNIT') && letters.contains('STAT')) {
            return 'US';
        }
        if (key == 'CA' || key == 'CANADA') {
            return 'CA';
        }
        if (key == 'GB' || key == 'UK' || key == 'UNITED KINGDOM') {
            return 'GB';
        }
        if (key == 'AU' || key == 'AUSTRALIA') {
            return 'AU';
        }
        if (key.length() == 2) {
            return key;
        }
        return null;
    }

    /**
     * Org requires complete shipping + country before state. After mapping/BillAddr:
     * - Convert known US state names to StateCode when possible
     * - Default country to US when a US state is present but country is blank/unrecognized
     * - Fill any remaining blank shipping fields from billing
     */
    private static void ensureAddressForDml(Account acc) {
        if (acc == null) {
            return;
        }
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Account.fields.getMap();

        maybeNormalizeUsState(acc, 'BillingState', 'BillingStateCode', fm);
        maybeNormalizeUsState(acc, 'ShippingState', 'ShippingStateCode', fm);

        // If state is set without country, default to US for US states / state codes
        if (needsCountry(acc, true) && looksLikeUsState(acc, true)) {
            if (fm.containsKey('billingcountrycode')) {
                acc.put('BillingCountryCode', 'US');
            } else if (String.isBlank(acc.BillingCountry)) {
                acc.BillingCountry = 'United States';
            }
        }
        if (needsCountry(acc, false) && looksLikeUsState(acc, false)) {
            if (fm.containsKey('shippingcountrycode')) {
                acc.put('ShippingCountryCode', 'US');
            } else if (String.isBlank(acc.ShippingCountry)) {
                acc.ShippingCountry = 'United States';
            }
        }

        // Complete shipping from billing (validation: "Please complete all Shipping Address fields")
        if (String.isBlank(acc.ShippingStreet) && String.isNotBlank(acc.BillingStreet)) {
            acc.ShippingStreet = acc.BillingStreet;
        }
        if (String.isBlank(acc.ShippingCity) && String.isNotBlank(acc.BillingCity)) {
            acc.ShippingCity = acc.BillingCity;
        }
        if (String.isBlank(acc.ShippingPostalCode) && String.isNotBlank(acc.BillingPostalCode)) {
            acc.ShippingPostalCode = acc.BillingPostalCode;
        }
        if (fm.containsKey('shippingstatecode') && acc.get('ShippingStateCode') == null && acc.get('BillingStateCode') != null) {
            acc.put('ShippingStateCode', acc.get('BillingStateCode'));
        } else if (String.isBlank(acc.ShippingState) && String.isNotBlank(acc.BillingState)) {
            acc.ShippingState = acc.BillingState;
        }
        if (fm.containsKey('shippingcountrycode') && acc.get('ShippingCountryCode') == null && acc.get('BillingCountryCode') != null) {
            acc.put('ShippingCountryCode', acc.get('BillingCountryCode'));
        } else if (String.isBlank(acc.ShippingCountry) && String.isNotBlank(acc.BillingCountry)) {
            acc.ShippingCountry = acc.BillingCountry;
        }

        clearConflictingAddressTextFields(acc);
    }

    private static Boolean needsCountry(Account acc, Boolean billing) {
        if (billing) {
            return acc.get('BillingCountryCode') == null && String.isBlank(acc.BillingCountry);
        }
        return acc.get('ShippingCountryCode') == null && String.isBlank(acc.ShippingCountry);
    }

    private static Boolean looksLikeUsState(Account acc, Boolean billing) {
        String code = billing
            ? (acc.get('BillingStateCode') != null ? String.valueOf(acc.get('BillingStateCode')) : null)
            : (acc.get('ShippingStateCode') != null ? String.valueOf(acc.get('ShippingStateCode')) : null);
        String name = billing ? acc.BillingState : acc.ShippingState;
        if (String.isNotBlank(code) && code.trim().length() == 2) {
            return true;
        }
        return usStateNameToCode(name) != null;
    }

    private static void maybeNormalizeUsState(
        Account acc,
        String stateField,
        String stateCodeField,
        Map<String, Schema.SObjectField> fm
    ) {
        if (!fm.containsKey(stateCodeField.toLowerCase())) {
            return;
        }
        if (acc.get(stateCodeField) != null) {
            return;
        }
        String stateText = (String) acc.get(stateField);
        String code = usStateNameToCode(stateText);
        if (code != null) {
            acc.put(stateCodeField, code);
            acc.put(stateField, null);
        }
    }

    private static String usStateNameToCode(String stateName) {
        if (String.isBlank(stateName)) {
            return null;
        }
        String key = stateName.trim().toUpperCase();
        if (key.length() == 2) {
            return key;
        }
        Map<String, String> names = new Map<String, String>{
            'ALABAMA' => 'AL', 'ALASKA' => 'AK', 'ARIZONA' => 'AZ', 'ARKANSAS' => 'AR',
            'CALIFORNIA' => 'CA', 'COLORADO' => 'CO', 'CONNECTICUT' => 'CT', 'DELAWARE' => 'DE',
            'FLORIDA' => 'FL', 'GEORGIA' => 'GA', 'HAWAII' => 'HI', 'IDAHO' => 'ID',
            'ILLINOIS' => 'IL', 'INDIANA' => 'IN', 'IOWA' => 'IA', 'KANSAS' => 'KS',
            'KENTUCKY' => 'KY', 'LOUISIANA' => 'LA', 'MAINE' => 'ME', 'MARYLAND' => 'MD',
            'MASSACHUSETTS' => 'MA', 'MICHIGAN' => 'MI', 'MINNESOTA' => 'MN', 'MISSISSIPPI' => 'MS',
            'MISSOURI' => 'MO', 'MONTANA' => 'MT', 'NEBRASKA' => 'NE', 'NEVADA' => 'NV',
            'NEW HAMPSHIRE' => 'NH', 'NEW JERSEY' => 'NJ', 'NEW MEXICO' => 'NM', 'NEW YORK' => 'NY',
            'NORTH CAROLINA' => 'NC', 'NORTH DAKOTA' => 'ND', 'OHIO' => 'OH', 'OKLAHOMA' => 'OK',
            'OREGON' => 'OR', 'PENNSYLVANIA' => 'PA', 'RHODE ISLAND' => 'RI', 'SOUTH CAROLINA' => 'SC',
            'SOUTH DAKOTA' => 'SD', 'TENNESSEE' => 'TN', 'TEXAS' => 'TX', 'UTAH' => 'UT',
            'VERMONT' => 'VT', 'VIRGINIA' => 'VA', 'WASHINGTON' => 'WA', 'WEST VIRGINIA' => 'WV',
            'WISCONSIN' => 'WI', 'WYOMING' => 'WY', 'DISTRICT OF COLUMBIA' => 'DC'
        };
        return names.get(key);
    }

    private static void putTaxLookup(Account acc, Map<String, Schema.SObjectField> fieldMap, Id taxId) {
        for (String candidate : new List<String>{
            'faxa__Tax__c', 'faxa__Quick_Book_Tax__c', 'Tax__c', 'Quick_Book_Tax__c', 'Tax_Group_Code__c'
        }) {
            if (!fieldMap.containsKey(candidate.toLowerCase())) {
                continue;
            }
            Schema.DescribeFieldResult d = fieldMap.get(candidate.toLowerCase()).getDescribe();
            if (d.isUpdateable() || d.isCreateable()) {
                acc.put(d.getName(), taxId);
                return;
            }
        }
    }

    private static void applyDefaultMapping(Account acc, Map<String, Object> qb, String qbId) {
        String display = resolveDisplayName(qb);
        acc.Name = String.isNotBlank(display) ? display : ('QB-Vendor-' + qbId);
        Object phone = getNested(qb, 'PrimaryPhone.FreeFormNumber');
        if (phone != null) {
            acc.Phone = String.valueOf(phone).left(40);
        }
        // Street/city/postal/country/state come from applyBillAddrFromQb /
        // applyShipAddrFromQbOrBilling (picklist-safe codes). Do not set BillingState="TX"
        // here — that mismatches BillingStateCode and fails DML.
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private void queueContinuation(Integer nextPage) {
        if (nextPage == null || nextPage < 1) {
            return;
        }
        pendingContinuationPage = nextPage;
    }

    private static Boolean isLowOnBudget() {
        if (Limits.getLimitQueries() - Limits.getQueries() < PAGE_SOQL_RESERVE) {
            return true;
        }
        if (Limits.getLimitDmlStatements() - Limits.getDmlStatements() < PAGE_DML_RESERVE) {
            return true;
        }
        if (Limits.getLimitCpuTime() - Limits.getCpuTime() < PAGE_CPU_RESERVE_MS) {
            return true;
        }
        return false;
    }

    private HttpResponse callQB(String endpoint) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Accept', 'application/json');
        req.setTimeout(60000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() == 401 || res.getStatusCode() == 403) {
            if (refreshAccessToken()) {
                req.setHeader('Authorization', 'Bearer ' + accessToken);
                res = new Http().send(req);
            }
        }
        return res;
    }

    private Boolean refreshAccessToken() {
        if (String.isBlank(refreshToken) || String.isBlank(clientId) || String.isBlank(clientSecret)) {
            return false;
        }
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(TOKEN_ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setHeader('Accept', 'application/json');
            req.setHeader(
                'Authorization',
                'Basic ' + EncodingUtil.base64Encode(Blob.valueOf(clientId + ':' + clientSecret))
            );
            req.setBody(
                'grant_type=refresh_token&refresh_token='
                + EncodingUtil.urlEncode(refreshToken, 'UTF-8')
            );

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200 || String.isBlank(res.getBody())) {
                return false;
            }

            Map<String, Object> tokenData = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String newAccess = (String) tokenData.get('access_token');
            if (String.isBlank(newAccess)) {
                return false;
            }
            accessToken = newAccess;
            String newRefresh = (String) tokenData.get('refresh_token');
            if (String.isNotBlank(newRefresh)) {
                refreshToken = newRefresh;
            }
            pendingTokenUpdate = new faxa__External_App__c(
                Id = externalAppId,
                faxa__Access_Token__c = accessToken,
                faxa__Refresh_Token__c = refreshToken
            );
            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Token refresh failed: ' + e.getMessage());
            return false;
        }
    }

    private static List<Object> parseVendorList(Map<String, Object> queryResponse) {
        if (queryResponse == null) {
            return new List<Object>();
        }
        Object listObj = queryResponse.get('Vendor');
        if (listObj instanceof List<Object>) {
            return (List<Object>) listObj;
        }
        if (listObj != null) {
            return new List<Object>{ listObj };
        }
        return new List<Object>();
    }

    private static Object getNested(Map<String, Object> data, String path) {
        if (data == null || String.isBlank(path)) {
            return null;
        }
        Object current = data;
        for (String p : path.split('\\.')) {
            if (!(current instanceof Map<String, Object>)) {
                return null;
            }
            current = ((Map<String, Object>) current).get(p);
        }
        return current;
    }

    private static String unwrapScalar(Object value) {
        if (value == null) {
            return null;
        }
        Object cur = value;
        Integer depth = 0;
        while (cur instanceof Map<String, Object> && depth < 8) {
            Map<String, Object> m = (Map<String, Object>) cur;
            if (m.containsKey('value')) {
                cur = m.get('value');
            } else if (m.containsKey('Address')) {
                cur = m.get('Address');
            } else if (m.containsKey('FreeFormNumber')) {
                cur = m.get('FreeFormNumber');
            } else if (m.containsKey('name')) {
                cur = m.get('name');
            } else {
                return null;
            }
            depth++;
        }
        return cur == null ? null : String.valueOf(cur).trim();
    }

    private static String resolveDisplayName(Map<String, Object> qb) {
        for (String k : new List<String>{ 'DisplayName', 'CompanyName', 'FullyQualifiedName' }) {
            Object o = getNested(qb, k);
            String s = unwrapScalar(o);
            if (String.isNotBlank(s)) {
                return collapseWhitespace(s).left(255);
            }
        }
        return null;
    }

    private static String normalizeQbId(Object idObj) {
        if (idObj == null) {
            return null;
        }
        try {
            if (idObj instanceof String) {
                String s = ((String) idObj).trim();
                if (String.isBlank(s)) {
                    return null;
                }
                try {
                    Decimal d = Decimal.valueOf(s);
                    Long lng = d.longValue();
                    if (Decimal.valueOf(lng) == d) {
                        return String.valueOf(lng);
                    }
                } catch (Exception ignore) { }
                return s;
            }
            Decimal d = idObj instanceof Decimal ? (Decimal) idObj : Decimal.valueOf(String.valueOf(idObj));
            Long lng = d.longValue();
            if (Decimal.valueOf(lng) == d) {
                return String.valueOf(lng);
            }
            return String.valueOf(d).trim();
        } catch (Exception e) {
            String s = String.valueOf(idObj).trim();
            return String.isBlank(s) ? null : s;
        }
    }

    private static String nameKey(String name) {
        if (name == null) {
            return null;
        }
        String c = collapseWhitespace(name.trim());
        return String.isBlank(c) ? null : c.toLowerCase();
    }

    private static String collapseWhitespace(String s) {
        if (s == null) {
            return null;
        }
        String t = s.trim();
        while (t.contains('  ')) {
            t = t.replace('  ', ' ');
        }
        return t;
    }

    private static Boolean isTaxCodePath(String qbPath) {
        if (String.isBlank(qbPath)) {
            return false;
        }
        String p = qbPath.trim().toLowerCase();
        return p.contains('taxcoderef') || p.contains('defaulttaxcode');
    }

    private static Boolean isTaxCodeRelatedField(String apiName) {
        if (String.isBlank(apiName)) {
            return false;
        }
        String lower = apiName.toLowerCase();
        return lower.contains('tax_code') || lower.contains('taxcode');
    }

    private static String truncate(String body) {
        if (body == null) {
            return null;
        }
        // Cap at 32,768 — some orgs report Long Text Area length as 131072 on describe
        // but the actual faxa__Response__c length is lower (STRING_TOO_LONG on insert).
        Integer maxLen = MAX_RESPONSE_LENGTH;
        try {
            Schema.SObjectField f = faxa__External_App_Request__c.SObjectType.getDescribe()
                .fields.getMap().get('faxa__response__c');
            if (f != null) {
                Integer described = f.getDescribe().getLength();
                if (described != null && described > 0 && described < maxLen) {
                    maxLen = described;
                }
            }
        } catch (Exception ignore) { /* use default */ }
        return body.length() > maxLen ? body.substring(0, maxLen) : body;
    }

    /** Insert audit request; never abort sync on Response field overflow. */
    private void insertRequestSafe(faxa__External_App_Request__c req) {
        if (req == null) {
            return;
        }
        req.faxa__Response__c = truncate(req.faxa__Response__c);
        try {
            insert req;
        } catch (DmlException e) {
            String msg = String.valueOf(e.getMessage());
            if (msg.contains('STRING_TOO_LONG') || msg.contains('too large')) {
                req.faxa__Response__c = null;
                insert req;
            } else {
                throw e;
            }
        }
    }

    public class BatchException extends Exception {}
}