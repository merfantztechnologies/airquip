/**
 * Fixed QB → SF Purchase Order sync (replacement for packaged QuickBooksPurchaseOrderFromQBSyncBatch).
 *
 * Root cause of "Too many SOQL queries: 201" in the package batch:
 *   1) Up to 100 POs per execute with per-Vendor / per-Customer / per-Item SOQL during mapping
 *   2) Reference caches only help after the first hit — unique refs across a page still N+1
 *   3) Account / Product / PO triggers amplify SOQL on DML
 *   4) Response body truncate at 131072 caused STRING_TOO_LONG on faxa__Response__c
 *
 * Fixes:
 *   - Smaller page size (25) + chained continuation (one page per transaction)
 *   - Bulk-prefetch Vendor / Customer / Product / Class lookups before mapping
 *   - Strip mapping path prefix "Line." so line Qty/Customer/Class map against line JSON
 *   - ShipAddr: join Line1–Line5 into Shipping Street; backfill city/state/postal/country
 *   - Resolve line Customer + Class lookups from prefetched caches
 *   - Bulk PO upsert + bulk line replace
 *   - Response truncated to 32,768 with safe insert retry
 *
 * Usage:
 *   Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(), 1);
 *   System.schedule('QB PO Sync Fixed', '0 0 7 * * ?', new QuickBooksPOFromQBSyncBatchFixed());
 *
 * Unschedule the packaged QuickBooksPurchaseOrderFromQBSyncBatch when using this class.
 */
public class QuickBooksPOFromQBSyncBatchFixed
    implements Database.Batchable<String>, Database.Stateful, Database.AllowsCallouts, Schedulable {

    private static final Integer QB_QUERY_PAGE_SIZE = 25;
    private static final Integer MAX_CONTINUATION_PAGE = 500;
    private static final String APP_NAME = 'QuickBook';
    private static final String FULL_SYNC_SCOPE = 'FULL_SYNC';
    private static final String TOKEN_ENDPOINT = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';
    private static final Integer MAX_RESPONSE_LENGTH = 32768;
    private static final Integer PAGE_SOQL_RESERVE = 80;
    private static final Integer PAGE_DML_RESERVE = 25;
    private static final Integer PAGE_CPU_RESERVE_MS = 15000;

    private static final String PO_OBJECT = 'faxa__Purchase_Order__c';
    private static final String LINE_OBJECT = 'faxa__Purchase_Order_Line__c';
    private static final String QB_PO_ID_FIELD = 'faxa__QuickBooks_PO_Id__c';
    private static final String LINE_PARENT_FIELD = 'faxa__Purchase_Order__c';

    private String realmId;
    private String accessToken;
    private String refreshToken;
    private String clientId;
    private String clientSecret;
    private Id externalAppId;
    private Boolean isSandbox;

    private List<faxa__Mapping__c> parentMappings;
    private List<faxa__Mapping__c> lineMappings;

    private Map<String, Id> vendorQbIdToAccountId = new Map<String, Id>();
    private Map<String, Id> customerQbIdToAccountId = new Map<String, Id>();
    private Map<String, Id> itemQbIdToProductId = new Map<String, Id>();
    private Map<String, Id> classQbIdToClassId = new Map<String, Id>();

    private faxa__External_App__c pendingTokenUpdate;
    private Integer startAtPage = 1;
    private Integer pendingContinuationPage;
    private Integer totalProcessed = 0;
    private Integer totalUpdated = 0;
    private Integer totalInserted = 0;
    private Integer totalSkippedNoChange = 0;
    private List<String> errors = new List<String>();

    public QuickBooksPOFromQBSyncBatchFixed() {
        this.isSandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }

    public QuickBooksPOFromQBSyncBatchFixed(Boolean isSandbox) {
        this.isSandbox = isSandbox;
    }

    public QuickBooksPOFromQBSyncBatchFixed(Integer startAtPageNumber) {
        this.isSandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
        this.startAtPage = (startAtPageNumber != null && startAtPageNumber > 0) ? startAtPageNumber : 1;
    }

    public QuickBooksPOFromQBSyncBatchFixed(Integer startAtPageNumber, Boolean isSandbox) {
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

        parentMappings = [
            SELECT faxa__FieldAx_Field__c, faxa__External_App_Field__c, faxa__External_Object__c, faxa__Default_Value__c
            FROM faxa__Mapping__c
            WHERE faxa__External_App__c = :externalAppId
            AND faxa__FieldAx_Object__c = :PO_OBJECT
            AND faxa__Is_Parent_Mapping__c = true
            ORDER BY faxa__Sequence__c NULLS LAST
        ];
        if (parentMappings.isEmpty()) {
            parentMappings = [
                SELECT faxa__FieldAx_Field__c, faxa__External_App_Field__c, faxa__External_Object__c, faxa__Default_Value__c
                FROM faxa__Mapping__c
                WHERE faxa__External_App__c = :externalAppId
                AND faxa__FieldAx_Object__c = :PO_OBJECT
                ORDER BY faxa__Sequence__c NULLS LAST
            ];
        }

        lineMappings = [
            SELECT faxa__FieldAx_Field__c, faxa__External_App_Field__c, faxa__Default_Value__c
            FROM faxa__Mapping__c
            WHERE faxa__External_App__c = :externalAppId
            AND faxa__FieldAx_Object__c = :LINE_OBJECT
            ORDER BY faxa__Sequence__c NULLS LAST
        ];

        return new List<String>{ FULL_SYNC_SCOPE };
    }

    public void execute(Database.BatchableContext bc, List<String> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }
        Integer pageIndex = (startAtPage != null && startAtPage > 0) ? startAtPage : 1;
        if (Limits.getCallouts() >= Limits.getLimitCallouts() || isLowOnBudget()) {
            errors.add('Paused before page ' + pageIndex + ' (governor headroom).');
            pendingContinuationPage = pageIndex;
            return;
        }
        Boolean mayHaveMore = processPurchaseOrderPage(pageIndex);
        if (mayHaveMore) {
            pendingContinuationPage = pageIndex + 1;
        }
    }

    public void finish(Database.BatchableContext bc) {
        if (pendingTokenUpdate != null && pendingTokenUpdate.Id != null) {
            try {
                update pendingTokenUpdate;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'PO Fixed: token save failed: ' + e.getMessage());
            }
        }
        System.debug(
            'QuickBooksPOFromQBSyncBatchFixed finished. Processed=' + totalProcessed
            + ', Updated=' + totalUpdated + ', Inserted=' + totalInserted
            + ', Skipped=' + totalSkippedNoChange
        );
        if (!errors.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'Errors: ' + String.join(errors, '; '));
        }
        if (pendingContinuationPage != null && pendingContinuationPage <= MAX_CONTINUATION_PAGE) {
            Database.executeBatch(
                new QuickBooksPOFromQBSyncBatchFixed(pendingContinuationPage, isSandbox),
                1
            );
        }
    }

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new QuickBooksPOFromQBSyncBatchFixed(), 1);
    }

    // ─── Page processing ──────────────────────────────────────────────────────

    private Boolean processPurchaseOrderPage(Integer pageIndex) {
        Integer startPosition = (pageIndex - 1) * QB_QUERY_PAGE_SIZE + 1;
        String baseUrl = isSandbox
            ? 'https://sandbox-quickbooks.api.intuit.com'
            : 'https://quickbooks.api.intuit.com';
        String query = 'select * from PurchaseOrder startposition ' + startPosition
            + ' maxresults ' + QB_QUERY_PAGE_SIZE;
        String endpoint = baseUrl + '/v3/company/' + realmId + '/query?query='
            + EncodingUtil.urlEncode(query, 'UTF-8');

        HttpResponse res = callQB(endpoint);
        String body = res != null ? res.getBody() : null;

        faxa__External_App_Request__c req = new faxa__External_App_Request__c(
            faxa__External_App__c = externalAppId,
            faxa__Object_Name__c = PO_OBJECT,
            faxa__Request_End_Point__c = endpoint,
            faxa__Request_Method__c = 'GET',
            faxa__Response__c = truncate(body)
        );

        if (res == null || res.getStatusCode() != 200) {
            Integer code = res != null ? res.getStatusCode() : 0;
            String errMsg = 'Page ' + pageIndex + ': QB API ' + code;
            errors.add(errMsg);
            insertRequestSafe(req);
            insertLog(req.Id, ('Failed: QB API ' + code).left(255), errMsg);
            return false;
        }
        if (String.isBlank(body)) {
            insertRequestSafe(req);
            insertLog(req.Id, 'Failed: Empty response', null);
            return false;
        }

        Map<String, Object> root;
        try {
            root = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (JSONException e) {
            errors.add('Page ' + pageIndex + ': Invalid JSON - ' + e.getMessage());
            insertRequestSafe(req);
            insertLog(req.Id, 'Failed: Invalid JSON', e.getMessage());
            return false;
        }

        List<Object> purchaseOrders = parsePurchaseOrderList(root);
        Boolean fullPage = purchaseOrders.size() == QB_QUERY_PAGE_SIZE;

        if (purchaseOrders.isEmpty()) {
            insertRequestSafe(req);
            insertLog(req.Id, ('Success: Page ' + pageIndex + ' - 0 purchase orders').left(255), null);
            return false;
        }

        List<Map<String, Object>> qbPos = new List<Map<String, Object>>();
        for (Object poObj : purchaseOrders) {
            if (poObj instanceof Map<String, Object>) {
                qbPos.add((Map<String, Object>) poObj);
            }
        }

        // FIX: bulk-prefetch all Vendor / Customer / Product refs for this page (2–3 SOQL)
        prefetchReferenceCaches(qbPos);

        insertRequestSafe(req);
        upsertPurchaseOrders(qbPos, req);

        String status = 'Success: Page ' + pageIndex + ' - JSON ' + purchaseOrders.size()
            + '; upd ' + totalUpdated + ', ins ' + totalInserted + ', skip ' + totalSkippedNoChange;
        if (!errors.isEmpty()) {
            status += '; err ' + errors[errors.size() - 1];
        }
        insertLog(req.Id, status.left(255), null);
        return fullPage;
    }

    // ─── Bulk reference prefetch (replaces N+1 SOQL in package) ───────────────

    private void prefetchReferenceCaches(List<Map<String, Object>> qbPos) {
        Set<String> vendorIds = new Set<String>();
        Set<String> customerIds = new Set<String>();
        Set<String> itemIds = new Set<String>();
        Set<String> classIds = new Set<String>();

        for (Map<String, Object> qbPo : qbPos) {
            addRefId(vendorIds, getNested(qbPo, 'VendorRef.value'));
            addRefId(vendorIds, getNested(qbPo, 'VendorRef'));
            addRefId(customerIds, getNested(qbPo, 'CustomerRef.value'));
            addRefId(customerIds, getNested(qbPo, 'ShipTo.CustomerRef.value'));
            Object linesObj = qbPo.get('Line');
            List<Object> lines = new List<Object>();
            if (linesObj instanceof List<Object>) {
                lines = (List<Object>) linesObj;
            } else if (linesObj != null) {
                lines.add(linesObj);
            }
            for (Object lineObj : lines) {
                if (!(lineObj instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> line = (Map<String, Object>) lineObj;
                addRefId(itemIds, getNested(line, 'ItemBasedExpenseLineDetail.ItemRef.value'));
                addRefId(itemIds, getNested(line, 'ItemBasedExpenseLineDetail.ItemRef'));
                // Per-line Customer / Class (mappings use Line.ItemBasedExpenseLineDetail.*Ref)
                addRefId(customerIds, getNested(line, 'ItemBasedExpenseLineDetail.CustomerRef.value'));
                addRefId(customerIds, getNested(line, 'ItemBasedExpenseLineDetail.CustomerRef'));
                addRefId(customerIds, getNested(line, 'AccountBasedExpenseLineDetail.CustomerRef.value'));
                addRefId(classIds, getNested(line, 'ItemBasedExpenseLineDetail.ClassRef.value'));
                addRefId(classIds, getNested(line, 'ItemBasedExpenseLineDetail.ClassRef'));
                addRefId(classIds, getNested(line, 'AccountBasedExpenseLineDetail.ClassRef.value'));
            }
        }

        vendorIds.removeAll(vendorQbIdToAccountId.keySet());
        customerIds.removeAll(customerQbIdToAccountId.keySet());
        itemIds.removeAll(itemQbIdToProductId.keySet());
        classIds.removeAll(classQbIdToClassId.keySet());

        if (!vendorIds.isEmpty()) {
            for (Account a : [
                SELECT Id, faxa__QuickBooks_Vendor_Id__c
                FROM Account
                WHERE faxa__QuickBooks_Vendor_Id__c IN :vendorIds
            ]) {
                String key = normalizeQbId(a.faxa__QuickBooks_Vendor_Id__c);
                if (String.isNotBlank(key) && !vendorQbIdToAccountId.containsKey(key)) {
                    vendorQbIdToAccountId.put(key, a.Id);
                }
            }
        }
        if (!customerIds.isEmpty()) {
            for (Account a : [
                SELECT Id, faxa__QuickBooks_Customer_Id__c
                FROM Account
                WHERE faxa__QuickBooks_Customer_Id__c IN :customerIds
            ]) {
                String key = normalizeQbId(a.faxa__QuickBooks_Customer_Id__c);
                if (String.isNotBlank(key) && !customerQbIdToAccountId.containsKey(key)) {
                    customerQbIdToAccountId.put(key, a.Id);
                }
            }
        }
        if (!itemIds.isEmpty()) {
            for (Product2 p : [
                SELECT Id, faxa__QuickBooks_Item_Id__c
                FROM Product2
                WHERE faxa__QuickBooks_Item_Id__c IN :itemIds
            ]) {
                String key = normalizeQbId(p.faxa__QuickBooks_Item_Id__c);
                if (String.isNotBlank(key) && !itemQbIdToProductId.containsKey(key)) {
                    itemQbIdToProductId.put(key, p.Id);
                }
            }
        }
        if (!classIds.isEmpty()) {
            for (faxa__Class__c cls : [
                SELECT Id, faxa__Class_Id__c
                FROM faxa__Class__c
                WHERE faxa__Class_Id__c IN :classIds
            ]) {
                String key = normalizeQbId(cls.faxa__Class_Id__c);
                if (String.isNotBlank(key) && !classQbIdToClassId.containsKey(key)) {
                    classQbIdToClassId.put(key, cls.Id);
                }
            }
        }
    }

    private static void addRefId(Set<String> idSet, Object raw) {
        String idVal = normalizeQbId(unwrapRef(raw));
        if (String.isNotBlank(idVal)) {
            idSet.add(idVal);
        }
    }

    // ─── Upsert headers + lines ───────────────────────────────────────────────

    private class StagedPo {
        Map<String, Object> qbPo;
        faxa__Purchase_Order__c staged;
        String qbPoId;
        Id poId;
    }

    private void upsertPurchaseOrders(List<Map<String, Object>> qbPos, faxa__External_App_Request__c appReq) {
        List<StagedPo> stagedList = new List<StagedPo>();
        Set<String> qbPoIds = new Set<String>();

        for (Map<String, Object> qbPo : qbPos) {
            faxa__Purchase_Order__c staged = mapPurchaseOrder(qbPo);
            if (staged == null) {
                continue;
            }
            totalProcessed++;
            StagedPo sp = new StagedPo();
            sp.qbPo = qbPo;
            sp.staged = staged;
            sp.qbPoId = normalizeQbId(staged.get(QB_PO_ID_FIELD));
            stagedList.add(sp);
            if (String.isNotBlank(sp.qbPoId)) {
                qbPoIds.add(sp.qbPoId);
            }
        }
        if (stagedList.isEmpty()) {
            return;
        }

        Set<String> compareFields = buildPurchaseOrderCompareFields(stagedList);

        Map<String, faxa__Purchase_Order__c> existingByQbId = new Map<String, faxa__Purchase_Order__c>();
        if (!qbPoIds.isEmpty()) {
            String soql = 'SELECT ' + String.join(new List<String>(compareFields), ', ')
                + ' FROM faxa__Purchase_Order__c WHERE faxa__QuickBooks_PO_Id__c IN :qbPoIds';
            for (faxa__Purchase_Order__c row : Database.query(soql)) {
                String key = normalizeQbId(row.faxa__QuickBooks_PO_Id__c);
                if (String.isNotBlank(key) && !existingByQbId.containsKey(key)) {
                    existingByQbId.put(key, row);
                }
            }
        }

        Set<String> names = new Set<String>();
        for (StagedPo sp : stagedList) {
            if (String.isNotBlank(sp.qbPoId) && existingByQbId.containsKey(sp.qbPoId)) {
                continue;
            }
            if (String.isNotBlank(sp.staged.Name)) {
                names.add(sp.staged.Name.trim());
            }
        }
        Map<String, faxa__Purchase_Order__c> existingByName = new Map<String, faxa__Purchase_Order__c>();
        if (!names.isEmpty()) {
            String soql = 'SELECT ' + String.join(new List<String>(compareFields), ', ')
                + ' FROM faxa__Purchase_Order__c WHERE Name IN :names'
                + ' AND (faxa__QuickBooks_PO_Id__c = null OR faxa__QuickBooks_PO_Id__c = \'\')';
            for (faxa__Purchase_Order__c row : Database.query(soql)) {
                if (String.isNotBlank(row.Name) && !existingByName.containsKey(row.Name.trim())) {
                    existingByName.put(row.Name.trim(), row);
                }
            }
        }

        List<faxa__Purchase_Order__c> toInsert = new List<faxa__Purchase_Order__c>();
        List<StagedPo> insertStaged = new List<StagedPo>();
        List<faxa__Purchase_Order__c> toUpdate = new List<faxa__Purchase_Order__c>();
        List<StagedPo> updateStaged = new List<StagedPo>();
        List<faxa__External_App_Request_Log__c> logs = new List<faxa__External_App_Request_Log__c>();

        for (StagedPo sp : stagedList) {
            faxa__Purchase_Order__c existing;
            if (String.isNotBlank(sp.qbPoId) && existingByQbId.containsKey(sp.qbPoId)) {
                existing = existingByQbId.get(sp.qbPoId);
            } else if (String.isNotBlank(sp.staged.Name)) {
                existing = existingByName.get(sp.staged.Name.trim());
            }
            if (existing != null) {
                sp.poId = existing.Id;
                faxa__Purchase_Order__c upd = buildUpdate(sp.staged, existing);
                if (hasChanges(upd, existing)) {
                    toUpdate.add(upd);
                    updateStaged.add(sp);
                } else {
                    totalSkippedNoChange++;
                    logs.add(buildDetailLog(appReq.Id, sp.poId, 'Skipped: No field changes', null));
                }
            } else {
                toInsert.add(sp.staged);
                insertStaged.add(sp);
            }
        }

        if (!toInsert.isEmpty()) {
            Database.SaveResult[] results = Database.insert(toInsert, false);
            for (Integer i = 0; i < results.size(); i++) {
                StagedPo sp = insertStaged[i];
                if (results[i].isSuccess()) {
                    sp.poId = results[i].getId();
                    totalInserted++;
                    logs.add(buildDetailLog(appReq.Id, sp.poId, 'Purchase Order inserted from QuickBooks', null));
                } else {
                    String errMsg = collectErrors(results[i]);
                    errors.add('PO insert: ' + errMsg);
                    logs.add(buildLog(appReq.Id, 'Failed: PO insert DML error', errMsg));
                }
            }
        }
        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] results = Database.update(toUpdate, false);
            for (Integer i = 0; i < results.size(); i++) {
                StagedPo sp = updateStaged[i];
                if (results[i].isSuccess()) {
                    totalUpdated++;
                    logs.add(buildDetailLog(appReq.Id, sp.poId, 'Purchase Order updated from QuickBooks', null));
                } else {
                    String errMsg = collectErrors(results[i]);
                    errors.add('PO update ' + sp.poId + ': ' + errMsg);
                    logs.add(buildDetailLog(appReq.Id, sp.poId, 'Failed: PO update DML error', errMsg));
                    sp.poId = null;
                }
            }
        }

        syncLinesBulk(stagedList, appReq, logs);

        if (!logs.isEmpty()) {
            try {
                insert logs;
            } catch (DmlException e) {
                errors.add('Log insert error: ' + e.getMessage());
            }
        }
    }

    private faxa__Purchase_Order__c mapPurchaseOrder(Map<String, Object> qbPo) {
        String qbId = normalizeQbId(qbPo.get('Id'));
        if (String.isBlank(qbId)) {
            return null;
        }
        faxa__Purchase_Order__c po = new faxa__Purchase_Order__c();
        po.put(QB_PO_ID_FIELD, qbId);
        Map<String, Schema.SObjectField> fm = faxa__Purchase_Order__c.SObjectType.getDescribe().fields.getMap();
        // Do not set Sync_to_QuickBooks here — before-insert trigger owns that flag.
        if (fmHasWritable(fm, 'faxa__integration_status__c')) {
            po.faxa__Integration_Status__c = 'Successful';
        }

        applyMappings(po, qbPo, parentMappings, fm, QB_PO_ID_FIELD);
        applyShipAddrFromQb(po, qbPo, fm);

        // Vendor / Customer lookups from prefetched caches (no SOQL)
        String vendorQbId = normalizeQbId(unwrapRef(getNested(qbPo, 'VendorRef')));
        if (String.isNotBlank(vendorQbId)) {
            Schema.SObjectField vendorIdToken = fm.get('faxa__quickbooks_vendor_id__c');
            if (vendorIdToken != null) {
                Schema.DescribeFieldResult vdf = vendorIdToken.getDescribe();
                if (vdf.isCreateable() || vdf.isUpdateable()) {
                    po.put('faxa__Quickbooks_Vendor_Id__c', vendorQbId);
                }
            }
            if (vendorQbIdToAccountId.containsKey(vendorQbId) && fm.containsKey('faxa__vendor__c')) {
                po.faxa__Vendor__c = vendorQbIdToAccountId.get(vendorQbId);
            }
        }
        String customerQbId = normalizeQbId(unwrapRef(
            firstNonNull(new List<Object>{
                getNested(qbPo, 'ShipTo.CustomerRef'),
                getNested(qbPo, 'CustomerRef')
            })
        ));
        if (String.isNotBlank(customerQbId)
            && customerQbIdToAccountId.containsKey(customerQbId)
            && fm.containsKey('faxa__ship_to_customer__c')) {
            po.faxa__Ship_To_Customer__c = customerQbIdToAccountId.get(customerQbId);
        }

        if (String.isBlank(po.Name)) {
            Object doc = qbPo.get('DocNumber');
            po.Name = (doc != null && String.isNotBlank(String.valueOf(doc)))
                ? String.valueOf(doc).left(80)
                : ('QB-PO-' + qbId);
        }
        // Due date fallback
        if (po.faxa__Due_Date__c == null) {
            Date due = parseDate(getNested(qbPo, 'DueDate'));
            if (due != null) {
                po.faxa__Due_Date__c = due;
            }
        }
        if (po.faxa__PO_Date__c == null) {
            Date txn = parseDate(getNested(qbPo, 'TxnDate'));
            if (txn != null) {
                po.faxa__PO_Date__c = txn;
            }
        }
        return po;
    }

    private static Boolean fmHasWritable(Map<String, Schema.SObjectField> fm, String apiLower) {
        if (fm == null || !fm.containsKey(apiLower)) {
            return false;
        }
        Schema.DescribeFieldResult d = fm.get(apiLower).getDescribe();
        return d.isCreateable() || d.isUpdateable();
    }

    private void syncLinesBulk(
        List<StagedPo> stagedList,
        faxa__External_App_Request__c appReq,
        List<faxa__External_App_Request_Log__c> logs
    ) {
        Set<Id> poIds = new Set<Id>();
        for (StagedPo sp : stagedList) {
            if (sp.poId != null) {
                poIds.add(sp.poId);
            }
        }
        if (poIds.isEmpty()) {
            return;
        }

        List<faxa__Purchase_Order_Line__c> existing = [
            SELECT Id FROM faxa__Purchase_Order_Line__c WHERE faxa__Purchase_Order__c IN :poIds
        ];
        if (!existing.isEmpty()) {
            try {
                delete existing;
            } catch (DmlException e) {
                errors.add('PO line delete error: ' + e.getMessage());
            }
        }

        Map<String, Schema.SObjectField> lineFm = faxa__Purchase_Order_Line__c.SObjectType.getDescribe().fields.getMap();
        List<faxa__Purchase_Order_Line__c> toInsert = new List<faxa__Purchase_Order_Line__c>();
        List<Id> parentIds = new List<Id>();

        for (StagedPo sp : stagedList) {
            if (sp.poId == null) {
                continue;
            }
            Object linesObj = sp.qbPo.get('Line');
            List<Object> qbLines = new List<Object>();
            if (linesObj instanceof List<Object>) {
                qbLines = (List<Object>) linesObj;
            } else if (linesObj != null) {
                qbLines.add(linesObj);
            }
            for (Object lineObj : qbLines) {
                if (!(lineObj instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> qbLine = (Map<String, Object>) lineObj;
                if (!shouldIncludeLine(qbLine)) {
                    continue;
                }
                faxa__Purchase_Order_Line__c lineRec = mapLine(qbLine, lineFm);
                if (lineRec == null) {
                    continue;
                }
                lineRec.put(LINE_PARENT_FIELD, sp.poId);
                toInsert.add(lineRec);
                parentIds.add(sp.poId);
            }
        }

        Map<Id, Integer> successByPo = new Map<Id, Integer>();
        if (!toInsert.isEmpty()) {
            Database.SaveResult[] results = Database.insert(toInsert, false);
            for (Integer i = 0; i < results.size(); i++) {
                Id parentId = parentIds[i];
                if (results[i].isSuccess()) {
                    successByPo.put(parentId, (successByPo.containsKey(parentId) ? successByPo.get(parentId) : 0) + 1);
                } else {
                    errors.add('PO line on ' + parentId + ': ' + collectErrors(results[i]));
                }
            }
        }
        for (Id poId : poIds) {
            Integer cnt = successByPo.containsKey(poId) ? successByPo.get(poId) : 0;
            logs.add(buildDetailLog(appReq.Id, poId, 'Synced ' + cnt + ' Purchase Order line(s) from QuickBooks', null));
        }
    }

    private faxa__Purchase_Order_Line__c mapLine(Map<String, Object> qbLine, Map<String, Schema.SObjectField> lineFm) {
        faxa__Purchase_Order_Line__c lineRec = new faxa__Purchase_Order_Line__c();
        if (lineMappings != null && !lineMappings.isEmpty()) {
            applyMappings(lineRec, qbLine, lineMappings, lineFm, null);
            // Nested ItemBasedExpenseLineDetail fields often need explicit flatten
            applyLineDetailFallbacks(lineRec, qbLine, lineFm);
        } else {
            applyLineDetailFallbacks(lineRec, qbLine, lineFm);
        }
        String itemQbId = normalizeQbId(unwrapRef(getNested(qbLine, 'ItemBasedExpenseLineDetail.ItemRef')));
        if (String.isNotBlank(itemQbId)) {
            Schema.SObjectField itemIdToken = lineFm.get('faxa__quickbooks_product_id__c');
            if (itemIdToken != null) {
                Schema.DescribeFieldResult idf = itemIdToken.getDescribe();
                if (idf.isCreateable() || idf.isUpdateable()) {
                    lineRec.put('faxa__QuickBooks_Product_Id__c', itemQbId);
                }
            }
            if (itemQbIdToProductId.containsKey(itemQbId) && lineFm.containsKey('faxa__product__c')) {
                lineRec.faxa__Product__c = itemQbIdToProductId.get(itemQbId);
            }
        }

        String customerQbId = normalizeQbId(unwrapRef(firstNonNull(new List<Object>{
            getNested(qbLine, 'ItemBasedExpenseLineDetail.CustomerRef'),
            getNested(qbLine, 'AccountBasedExpenseLineDetail.CustomerRef')
        })));
        if (String.isNotBlank(customerQbId)) {
            putIfBlank(lineRec, lineFm, 'faxa__Quickbooks_Customer_Id__c', customerQbId);
            if (customerQbIdToAccountId.containsKey(customerQbId) && lineFm.containsKey('faxa__customer__c')) {
                lineRec.faxa__Customer__c = customerQbIdToAccountId.get(customerQbId);
            }
        }

        String classQbId = normalizeQbId(unwrapRef(firstNonNull(new List<Object>{
            getNested(qbLine, 'ItemBasedExpenseLineDetail.ClassRef'),
            getNested(qbLine, 'AccountBasedExpenseLineDetail.ClassRef')
        })));
        if (String.isNotBlank(classQbId)) {
            putIfBlank(lineRec, lineFm, 'faxa__QuickBooks_Class_Id__c', classQbId);
            if (classQbIdToClassId.containsKey(classQbId) && lineFm.containsKey('faxa__quickbooks_class__c')) {
                lineRec.faxa__QuickBooks_Class__c = classQbIdToClassId.get(classQbId);
            }
        }
        return lineRec;
    }

    private void applyLineDetailFallbacks(
        faxa__Purchase_Order_Line__c lineRec,
        Map<String, Object> qbLine,
        Map<String, Schema.SObjectField> lineFm
    ) {
        putIfBlank(lineRec, lineFm, 'faxa__Description__c', qbLine.get('Description'));
        putIfBlank(lineRec, lineFm, 'faxa__Amount__c', qbLine.get('Amount'));
        Object qty = firstNonNull(new List<Object>{
            getNested(qbLine, 'ItemBasedExpenseLineDetail.Qty'),
            getNested(qbLine, 'AccountBasedExpenseLineDetail.Qty')
        });
        Object unitPrice = firstNonNull(new List<Object>{
            getNested(qbLine, 'ItemBasedExpenseLineDetail.UnitPrice'),
            getNested(qbLine, 'AccountBasedExpenseLineDetail.UnitPrice')
        });
        putIfBlank(lineRec, lineFm, 'faxa__Quantity__c', qty);
        putIfBlank(lineRec, lineFm, 'faxa__Unit_Price__c', unitPrice);
    }

    private Boolean shouldIncludeLine(Map<String, Object> qbLine) {
        if (qbLine == null) {
            return false;
        }
        Object detailType = qbLine.get('DetailType');
        if (detailType == null) {
            return true;
        }
        String dt = String.valueOf(detailType);
        // Skip subtotals
        if ('SubTotalLineDetail'.equalsIgnoreCase(dt)) {
            return false;
        }
        if (lineMappings == null || lineMappings.isEmpty()) {
            return true;
        }
        Set<String> allowed = new Set<String>();
        for (faxa__Mapping__c m : lineMappings) {
            if (m != null && String.isNotBlank(m.faxa__Default_Value__c)
                && m.faxa__External_App_Field__c != null
                && m.faxa__External_App_Field__c.toLowerCase().contains('detailtype')) {
                allowed.add(m.faxa__Default_Value__c.trim());
            }
        }
        return allowed.isEmpty() || allowed.contains(dt.trim());
    }

    // ─── Mapping helpers ──────────────────────────────────────────────────────

    private void applyMappings(
        SObject target,
        Map<String, Object> qbData,
        List<faxa__Mapping__c> mappings,
        Map<String, Schema.SObjectField> fieldMap,
        String skipFieldApi
    ) {
        if (mappings == null || target == null || qbData == null) {
            return;
        }
        for (faxa__Mapping__c m : mappings) {
            if (m == null || String.isBlank(m.faxa__FieldAx_Field__c) || String.isBlank(m.faxa__External_App_Field__c)) {
                continue;
            }
            String sfField = m.faxa__FieldAx_Field__c.trim();
            if (sfField.contains(',')) {
                sfField = sfField.split(',')[0].trim();
            }
            if (!fieldMap.containsKey(sfField.toLowerCase())) {
                continue;
            }
            if (String.isNotBlank(skipFieldApi) && sfField.equalsIgnoreCase(skipFieldApi)) {
                continue;
            }
            Schema.DescribeFieldResult dfr = fieldMap.get(sfField.toLowerCase()).getDescribe();
            if (!dfr.isCreateable() && !dfr.isUpdateable()) {
                continue;
            }
            // Skip REFERENCE — resolved via prefetch + explicit lookup puts
            if (dfr.getType() == Schema.DisplayType.REFERENCE) {
                continue;
            }
            String path = normalizeMappingPath(m.faxa__External_App_Field__c.trim());
            Object qbValue = getNested(qbData, path);
            if (isAbsent(qbValue)) {
                continue;
            }
            setField(target, sfField, qbValue, dfr);
        }
    }

    /**
     * Org mappings for PO lines are stored as Line.ItemBasedExpenseLineDetail.* against the parent
     * PurchaseOrder payload. When applying to a single Line map, strip the Line. / Line[n]. prefix.
     */
    private static String normalizeMappingPath(String path) {
        if (String.isBlank(path)) {
            return path;
        }
        String p = path.trim();
        String lower = p.toLowerCase();
        if (lower.startsWith('line.')) {
            return p.substring(5);
        }
        // Line[1].ItemBasedExpenseLineDetail.Qty → ItemBasedExpenseLineDetail.Qty
        if (lower.startsWith('line[') && p.contains('].')) {
            Integer close = p.indexOf('].');
            if (close > 0 && close + 2 < p.length()) {
                return p.substring(close + 2);
            }
        }
        return p;
    }

    /**
     * Map ShipAddr into discrete SF fields:
     *   Street ← Line1 (+ Line2 when present). Do NOT dump City/State/ZIP into Street.
     *   City / State / Postal / Country ← structured ShipAddr fields (overwrite from QB).
     * If City is blank and a later Line looks like "City, ST ZIP", parse that line.
     */
    private static void applyShipAddrFromQb(
        faxa__Purchase_Order__c po,
        Map<String, Object> qbPo,
        Map<String, Schema.SObjectField> fm
    ) {
        Object shipObj = qbPo.get('ShipAddr');
        if (!(shipObj instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> ship = (Map<String, Object>) shipObj;

        String city = trimToNull(ship.get('City'));
        String state = trimToNull(ship.get('CountrySubDivisionCode'));
        String postal = trimToNull(ship.get('PostalCode'));
        String country = trimToNull(ship.get('Country'));

        List<String> streetParts = new List<String>();
        for (Integer i = 1; i <= 5; i++) {
            Object lineVal = ship.get('Line' + i);
            String part = trimToNull(lineVal);
            if (part == null) {
                continue;
            }
            // Lines 3–5 often repeat city/state/zip as free text — parse instead of stuffing into Street
            if (i >= 3) {
                if (city == null || state == null || postal == null) {
                    Map<String, String> parsed = parseCityStatePostalLine(part);
                    if (parsed != null) {
                        if (city == null && parsed.containsKey('city')) {
                            city = parsed.get('city');
                        }
                        if (state == null && parsed.containsKey('state')) {
                            state = parsed.get('state');
                        }
                        if (postal == null && parsed.containsKey('postal')) {
                            postal = parsed.get('postal');
                        }
                        continue;
                    }
                } else {
                    // Already have structured city/state/postal — skip address lines that only echo them
                    continue;
                }
            }
            streetParts.add(part);
        }

        if (!streetParts.isEmpty()) {
            String fullStreet = String.join(streetParts, '\n');
            Schema.SObjectField streetToken = fm.get('faxa__shipping_street__c');
            if (streetToken != null) {
                Schema.DescribeFieldResult sd = streetToken.getDescribe();
                if (sd.isCreateable() || sd.isUpdateable()) {
                    Integer maxLen = sd.getLength();
                    if (maxLen != null && maxLen > 0 && fullStreet.length() > maxLen) {
                        fullStreet = fullStreet.left(maxLen);
                    }
                    po.put('faxa__Shipping_Street__c', fullStreet);
                }
            }
        }
        // Always drive city/state/postal/country from ShipAddr (mappings often leave blanks)
        putAddressField(po, fm, 'faxa__Shipping_City__c', city);
        putAddressField(po, fm, 'faxa__Shipping_State__c', state);
        putAddressField(po, fm, 'faxa__Shipping_Postal_Code__c', postal);
        if (country == null && state != null) {
            country = 'United States';
        } else if (country != null) {
            String lower = country.toLowerCase();
            if (lower == 'usa' || lower == 'us') {
                country = 'United States';
            }
        }
        putAddressField(po, fm, 'faxa__Shipping_Country__c', country);
    }

    private static String trimToNull(Object raw) {
        if (raw == null) {
            return null;
        }
        String s = String.valueOf(raw).trim();
        return String.isBlank(s) ? null : s;
    }

    private static void putAddressField(
        SObject target,
        Map<String, Schema.SObjectField> fm,
        String fieldApi,
        String value
    ) {
        if (String.isBlank(value) || fm == null || !fm.containsKey(fieldApi.toLowerCase())) {
            return;
        }
        Schema.DescribeFieldResult dfr = fm.get(fieldApi.toLowerCase()).getDescribe();
        if (!dfr.isCreateable() && !dfr.isUpdateable()) {
            return;
        }
        setField(target, fieldApi, value, dfr);
    }

    /** Parses lines like "San Pablo, CA 87999" or "San Pablo, CA, 87999". */
    private static Map<String, String> parseCityStatePostalLine(String line) {
        if (String.isBlank(line) || !line.contains(',')) {
            return null;
        }
        // City, ST ZIP  |  City, ST, ZIP  |  City, State ZIP
        Pattern p = Pattern.compile(
            '^\\s*(.+?)\\s*,\\s*([A-Za-z]{2}|[A-Za-z][A-Za-z\\s]+?)\\s*,?\\s*(\\d{5}(?:-\\d{4})?)?\\s*$'
        );
        Matcher m = p.matcher(line.trim());
        if (!m.matches()) {
            return null;
        }
        Map<String, String> out = new Map<String, String>();
        out.put('city', m.group(1).trim());
        out.put('state', m.group(2).trim());
        if (String.isNotBlank(m.group(3))) {
            out.put('postal', m.group(3).trim());
        }
        return out;
    }

    private static void setField(SObject target, String fieldName, Object value, Schema.DescribeFieldResult dfr) {
        Object scalar = unwrapRef(value);
        if (scalar == null) {
            return;
        }
        Schema.DisplayType ft = dfr.getType();
        try {
            if (ft == Schema.DisplayType.DATE) {
                Date d = parseDate(scalar);
                if (d != null) {
                    target.put(fieldName, d);
                }
                return;
            }
            if (ft == Schema.DisplayType.DATETIME) {
                Date d = parseDate(scalar);
                if (d != null) {
                    target.put(fieldName, DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0)));
                }
                return;
            }
            String strVal = String.valueOf(scalar).trim();
            if (String.isBlank(strVal)) {
                return;
            }
            if (ft == Schema.DisplayType.DOUBLE || ft == Schema.DisplayType.CURRENCY || ft == Schema.DisplayType.PERCENT) {
                target.put(fieldName, Decimal.valueOf(strVal.replace(',', '')));
                return;
            }
            if (ft == Schema.DisplayType.INTEGER) {
                target.put(fieldName, Integer.valueOf(strVal));
                return;
            }
            if (ft == Schema.DisplayType.BOOLEAN) {
                target.put(fieldName, 'true'.equalsIgnoreCase(strVal) || '1'.equals(strVal));
                return;
            }
            Integer maxLen = dfr.getLength();
            if (maxLen != null && maxLen > 0 && strVal.length() > maxLen) {
                strVal = strVal.left(maxLen);
            }
            target.put(fieldName, strVal);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'PO Fixed setField ' + fieldName + ': ' + e.getMessage());
        }
    }

    private static void putIfBlank(
        SObject target,
        Map<String, Schema.SObjectField> fm,
        String fieldApi,
        Object value
    ) {
        if (!fm.containsKey(fieldApi.toLowerCase()) || isAbsent(value)) {
            return;
        }
        Object existing = target.get(fieldApi);
        if (existing != null && String.isNotBlank(String.valueOf(existing))) {
            return;
        }
        setField(target, fieldApi, value, fm.get(fieldApi.toLowerCase()).getDescribe());
    }

    private faxa__Purchase_Order__c buildUpdate(faxa__Purchase_Order__c staged, faxa__Purchase_Order__c existing) {
        faxa__Purchase_Order__c upd = new faxa__Purchase_Order__c(Id = existing.Id);
        Map<String, Schema.SObjectField> fm = faxa__Purchase_Order__c.SObjectType.getDescribe().fields.getMap();
        for (String fieldName : staged.getPopulatedFieldsAsMap().keySet()) {
            if (fieldName == 'Id') {
                continue;
            }
            Schema.SObjectField token = fm.get(fieldName.toLowerCase());
            if (token == null || !token.getDescribe().isUpdateable()) {
                continue;
            }
            upd.put(fieldName, staged.get(fieldName));
        }
        return upd;
    }

    private Boolean hasChanges(faxa__Purchase_Order__c upd, faxa__Purchase_Order__c existing) {
        Map<String, Object> existingFields = existing != null
            ? existing.getPopulatedFieldsAsMap()
            : new Map<String, Object>();
        for (String fieldName : upd.getPopulatedFieldsAsMap().keySet()) {
            if (fieldName == 'Id') {
                continue;
            }
            // Avoid SObjectException when field was not queried on existing
            if (!existingFields.containsKey(fieldName)) {
                return true;
            }
            String nv = upd.get(fieldName) == null ? '' : String.valueOf(upd.get(fieldName)).trim();
            String ov = existing.get(fieldName) == null ? '' : String.valueOf(existing.get(fieldName)).trim();
            if (!nv.equals(ov)) {
                return true;
            }
        }
        return false;
    }

    /** Dynamic SELECT list so change-detection never misses mapped fields (e.g. Shipping_Street). */
    private Set<String> buildPurchaseOrderCompareFields(List<StagedPo> stagedList) {
        Set<String> fields = new Set<String>{
            'Id',
            'Name',
            QB_PO_ID_FIELD,
            'faxa__Vendor__c',
            'faxa__Ship_To_Customer__c',
            'faxa__PO_Date__c',
            'faxa__Due_Date__c',
            'faxa__Status__c',
            'faxa__Sync_to_QuickBooks__c',
            'faxa__Integration_Status__c'
        };
        Map<String, Schema.SObjectField> fm = faxa__Purchase_Order__c.SObjectType.getDescribe().fields.getMap();
        if (parentMappings != null) {
            for (faxa__Mapping__c m : parentMappings) {
                if (m == null || String.isBlank(m.faxa__FieldAx_Field__c)) {
                    continue;
                }
                String sfField = m.faxa__FieldAx_Field__c.trim();
                if (sfField.contains(',')) {
                    sfField = sfField.split(',')[0].trim();
                }
                if (fm.containsKey(sfField.toLowerCase())) {
                    fields.add(fm.get(sfField.toLowerCase()).getDescribe().getName());
                }
            }
        }
        if (stagedList != null) {
            for (StagedPo sp : stagedList) {
                if (sp == null || sp.staged == null) {
                    continue;
                }
                for (String fieldName : sp.staged.getPopulatedFieldsAsMap().keySet()) {
                    if (fm.containsKey(fieldName.toLowerCase())) {
                        fields.add(fm.get(fieldName.toLowerCase()).getDescribe().getName());
                    }
                }
            }
        }
        // Drop non-selectable / formula-only if somehow added — only keep queryable fields
        Set<String> selectable = new Set<String>();
        for (String f : fields) {
            Schema.SObjectField token = fm.get(f.toLowerCase());
            if (token == null) {
                continue;
            }
            Schema.DescribeFieldResult d = token.getDescribe();
            if (d.isAccessible()) {
                selectable.add(d.getName());
            }
        }
        return selectable;
    }

    // ─── HTTP / audit ─────────────────────────────────────────────────────────

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
            req.setBody('grant_type=refresh_token&refresh_token=' + EncodingUtil.urlEncode(refreshToken, 'UTF-8'));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200 || String.isBlank(res.getBody())) {
                return false;
            }
            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String newAccess = (String) data.get('access_token');
            if (String.isBlank(newAccess)) {
                return false;
            }
            accessToken = newAccess;
            String newRefresh = (String) data.get('refresh_token');
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
            System.debug(LoggingLevel.WARN, 'PO Fixed token refresh: ' + e.getMessage());
            return false;
        }
    }

    private void insertRequestSafe(faxa__External_App_Request__c req) {
        req.faxa__Response__c = truncate(req.faxa__Response__c);
        try {
            insert req;
        } catch (DmlException e) {
            String msg = String.valueOf(e.getMessage());
            if (msg.contains('STRING_TOO_LONG') || msg.contains('too large')) {
                req.faxa__Response__c = null;
                insert req;
            } else {
                errors.add('Request insert error: ' + msg);
            }
        }
    }

    private void insertLog(Id requestId, String status, String errorMsg) {
        try {
            insert buildLog(requestId, status, errorMsg);
        } catch (DmlException e) {
            errors.add('Log insert error: ' + e.getMessage());
        }
    }

    private faxa__External_App_Request_Log__c buildLog(Id requestId, String status, String errorMsg) {
        faxa__External_App_Request_Log__c log = new faxa__External_App_Request_Log__c();
        log.faxa__QB_Http_Request__c = requestId;
        log.faxa__Status__c = status != null && status.length() > 255 ? status.left(255) : status;
        if (String.isNotBlank(errorMsg)) {
            log.faxa__Error_Message__c = errorMsg.length() > 32768 ? errorMsg.left(32768) : errorMsg;
        }
        return log;
    }

    private faxa__External_App_Request_Log__c buildDetailLog(Id requestId, Id recordId, String status, String errorMsg) {
        faxa__External_App_Request_Log__c log = buildLog(requestId, status, errorMsg);
        if (recordId != null) {
            log.faxa__Record_Id__c = recordId;
        }
        return log;
    }

    // ─── Utils ────────────────────────────────────────────────────────────────

    private static Boolean isLowOnBudget() {
        return (Limits.getLimitQueries() - Limits.getQueries() < PAGE_SOQL_RESERVE)
            || (Limits.getLimitDmlStatements() - Limits.getDmlStatements() < PAGE_DML_RESERVE)
            || (Limits.getLimitCpuTime() - Limits.getCpuTime() < PAGE_CPU_RESERVE_MS);
    }

    private static List<Object> parsePurchaseOrderList(Map<String, Object> root) {
        if (root == null) {
            return new List<Object>();
        }
        Map<String, Object> qr = (Map<String, Object>) root.get('QueryResponse');
        if (qr != null) {
            Object listObj = qr.get('PurchaseOrder');
            if (listObj instanceof List<Object>) {
                return (List<Object>) listObj;
            }
            if (listObj != null) {
                return new List<Object>{ listObj };
            }
        }
        Object direct = root.get('PurchaseOrder');
        if (direct instanceof List<Object>) {
            return (List<Object>) direct;
        }
        if (direct instanceof Map<String, Object>) {
            return new List<Object>{ direct };
        }
        return new List<Object>();
    }

    private static Object getNested(Map<String, Object> data, String path) {
        if (data == null || String.isBlank(path)) {
            return null;
        }
        Object current = data;
        for (String key : path.split('\\.')) {
            if (!(current instanceof Map<String, Object>)) {
                return null;
            }
            current = ((Map<String, Object>) current).get(key);
        }
        return current;
    }

    private static Object unwrapRef(Object value) {
        if (value == null) {
            return null;
        }
        Object cur = value;
        Integer depth = 0;
        while (cur instanceof Map<String, Object> && depth < 8) {
            Map<String, Object> m = (Map<String, Object>) cur;
            if (m.containsKey('value')) {
                cur = m.get('value');
            } else if (m.containsKey('name')) {
                cur = m.get('name');
            } else {
                return null;
            }
            depth++;
        }
        return cur;
    }

    private static Boolean isAbsent(Object value) {
        Object n = unwrapRef(value);
        return n == null || String.isBlank(String.valueOf(n));
    }

    private static Object firstNonNull(List<Object> values) {
        for (Object v : values) {
            if (v != null) {
                return v;
            }
        }
        return null;
    }

    private static Date parseDate(Object scalar) {
        if (scalar == null) {
            return null;
        }
        if (scalar instanceof Date) {
            return (Date) scalar;
        }
        String s = String.valueOf(unwrapRef(scalar)).trim();
        if (String.isBlank(s)) {
            return null;
        }
        try {
            return Date.valueOf(s.length() >= 10 ? s.substring(0, 10) : s);
        } catch (Exception e) {
            try {
                return Date.parse(s);
            } catch (Exception e2) {
                return null;
            }
        }
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

    private static String truncate(String body) {
        if (body == null) {
            return null;
        }
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
        } catch (Exception ignore) { }
        return body.length() > maxLen ? body.substring(0, maxLen) : body;
    }

    private static String collectErrors(Database.SaveResult sr) {
        if (sr == null || sr.isSuccess() || sr.getErrors() == null || sr.getErrors().isEmpty()) {
            return 'Unknown DML error';
        }
        List<String> msgs = new List<String>();
        for (Database.Error err : sr.getErrors()) {
            if (err != null) {
                msgs.add(err.getMessage());
            }
        }
        return msgs.isEmpty() ? 'Unknown DML error' : String.join(msgs, '; ');
    }

    public class BatchException extends Exception {}
}