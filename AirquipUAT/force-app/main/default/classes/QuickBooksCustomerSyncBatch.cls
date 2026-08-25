public class QuickBooksCustomerSyncBatch 
implements Database.Batchable<String>, Database.Stateful, Database.AllowsCallouts {

    private static final Integer PAGE_SIZE = 1000;
    private static final String APP_NAME = 'QuickBook';
    private static final String TOKEN_ENDPOINT = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';

    private String realmId;
    private String accessToken;
    private String refreshToken;
    private String clientId;
    private String clientSecret;
    private Boolean isSandbox;

    private Id externalAppId;

    public QuickBooksCustomerSyncBatch() {
        this.isSandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }

    public QuickBooksCustomerSyncBatch(Boolean isSandbox) {
        this.isSandbox = isSandbox;
    }

    private List<faxa__Mapping__c> mappings;

    private Map<String, Id> taxCodeMap;

    private faxa__External_App__c pendingTokenUpdate;

    // ================= START =================
    public Iterable<String> start(Database.BatchableContext bc) {

        faxa__External_App__c app = [
            SELECT Id, faxa__Realm_ID__c, faxa__Access_Token__c,
                   faxa__Refresh_Token__c, faxa__Client_Id__c,
                   faxa__Client_Secret__c, faxa__Authentication_Status__c
            FROM faxa__External_App__c
            WHERE Name = :APP_NAME LIMIT 1
        ];

        if (app == null || app.faxa__Authentication_Status__c != 'Successful') {
            throw new BatchException('QuickBooks not authenticated');
        }

        realmId = app.faxa__Realm_ID__c;
        accessToken = app.faxa__Access_Token__c;
        refreshToken = app.faxa__Refresh_Token__c;
        clientId = app.faxa__Client_Id__c;
        clientSecret = app.faxa__Client_Secret__c;
        externalAppId = app.Id;

        mappings = [
            SELECT faxa__FieldAx_Field__c, faxa__External_App_Field__c
            FROM faxa__Mapping__c
            WHERE faxa__FieldAx_Object__c = 'Account'
        ];

        taxCodeMap = new Map<String, Id>();
        for (faxa__Tax__c t : [SELECT Id, faxa__Tax_Code_Id__c FROM faxa__Tax__c WHERE faxa__Tax_Code_Id__c != null]) {
            taxCodeMap.put(t.faxa__Tax_Code_Id__c, t.Id);
        }

        return new List<String>{ 'RUN' };
    }

    // ================= EXECUTE =================
    public void execute(Database.BatchableContext bc, List<String> scope) {

        String baseUrl = isSandbox
            ? 'https://sandbox-quickbooks.api.intuit.com'
            : 'https://quickbooks.api.intuit.com';

        // Phase 1: ALL callouts first (no DML allowed before callouts)
        List<PageResult> pageResults = new List<PageResult>();
        Integer page = 1;

        while (true) {
            String query = 'select * from Customer startposition ' +
                           ((page - 1) * PAGE_SIZE + 1) +
                           ' maxresults ' + PAGE_SIZE;

            String endpoint = baseUrl + '/v3/company/' + realmId +
                '/query?query=' + EncodingUtil.urlEncode(query, 'UTF-8');

            HttpResponse res = callQB(endpoint);

            PageResult pr = new PageResult();
            pr.endpoint = endpoint;
            pr.res = res;
            pr.responseBody = res != null ? res.getBody() : null;
            if (pr.responseBody != null && pr.responseBody.length() > 32768) {
                pr.responseBody = pr.responseBody.substring(0, 32768);
            }
            pageResults.add(pr);

            if (res == null || res.getStatusCode() != 200) break;

            Map<String, Object> data =
                (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> qr =
                (Map<String, Object>) data.get('QueryResponse');
            List<Object> customers =
                (List<Object>) qr.get('Customer');

            if (customers == null || customers.isEmpty()) break;

            pr.customers = customers;

            if (customers.size() < PAGE_SIZE) break;
            page++;
        }

        // Phase 2: ALL DML after callouts complete
        for (PageResult pr : pageResults) {
            processPageResult(pr);
        }
    }

    // ================= PROCESS PAGE RESULT =================
    private void processPageResult(PageResult pr) {

        faxa__External_App_Request__c req = new faxa__External_App_Request__c(
            faxa__External_App__c = externalAppId,
            faxa__Object_Name__c = 'Account',
            faxa__Request_End_Point__c = pr.endpoint,
            faxa__Request_Method__c = 'GET',
            faxa__Response__c = pr.responseBody
        );
        insert req;

        if (pr.res == null || pr.res.getStatusCode() != 200) {
            String errMsg = 'Callout failed';
            if (pr.res != null) {
                errMsg += ' - HTTP ' + pr.res.getStatusCode() + ': ' + pr.responseBody;
            }

            insert new faxa__External_App_Request_Log__c(
                faxa__Status__c = 'Failed',
                faxa__Error_Message__c = errMsg.abbreviate(32768),
                faxa__QB_Http_Request__c = req.Id
            );
            return;
        }

        if (pr.customers == null || pr.customers.isEmpty()) return;

        List<Account> accounts = new List<Account>();
        for (Object obj : pr.customers) {
            Account acc = mapDynamic((Map<String, Object>) obj);
            if (acc != null) accounts.add(acc);
        }

        Database.DMLOptions dmlOpts = new Database.DMLOptions();
        dmlOpts.DuplicateRuleHeader.allowSave = true;
        dmlOpts.optAllOrNone = false;

        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();
        Set<String> queryFields = new Set<String>{'Id', 'Name', 'faxa__QuickBooks_Customer_Id__c'};
        for (faxa__Mapping__c m : mappings) {
            String sf = m.faxa__FieldAx_Field__c;
            if (sf == null) continue;
            Schema.SObjectField ft = fieldMap.get(sf.toLowerCase());
            if (ft != null && ft.getDescribe().isUpdateable()) {
                queryFields.add(sf);
            }
        }
        for (String addrField : new List<String>{
            'BillingStreet','BillingCity','BillingState','BillingPostalCode','BillingCountry','BillingCountryCode',
            'ShippingStreet','ShippingCity','ShippingState','ShippingPostalCode','ShippingCountry','ShippingCountryCode','Phone'
        }) {
            if (fieldMap.containsKey(addrField.toLowerCase())) queryFields.add(addrField);
        }
        String fieldList = String.join(new List<String>(queryFields), ', ');

        Set<String> qbIds = new Set<String>();
        Set<String> accNames = new Set<String>();
        for (Account a : accounts) {
            String qbId = (String) a.get('faxa__QuickBooks_Customer_Id__c');
            if (String.isNotBlank(qbId)) qbIds.add(qbId);
            String accName = (String) a.get('Name');
            if (String.isNotBlank(accName)) accNames.add(accName);
        }

        Map<String, Account> existingByQbId = new Map<String, Account>();
        for (Account ex : Database.query('SELECT ' + fieldList + ' FROM Account WHERE faxa__QuickBooks_Customer_Id__c IN :qbIds')) {
            existingByQbId.put(ex.faxa__QuickBooks_Customer_Id__c, ex);
        }

        Map<String, Account> existingByName = new Map<String, Account>();
        if (!accNames.isEmpty()) {
            for (Account ex : Database.query('SELECT ' + fieldList + ' FROM Account WHERE Name IN :accNames AND faxa__QuickBooks_Customer_Id__c = null')) {
                String key = ex.Name.toLowerCase();
                if (!existingByName.containsKey(key)) {
                    existingByName.put(key, ex);
                }
            }
        }

        List<Account> toInsert = new List<Account>();
        Map<Id, Account> toUpdateMap = new Map<Id, Account>();
        Set<Id> matchedIds = new Set<Id>();
        for (Account a : accounts) {
            String qbId = (String) a.get('faxa__QuickBooks_Customer_Id__c');
            Account match = existingByQbId.get(qbId);

            if (match == null) {
                String accName = (String) a.get('Name');
                if (String.isNotBlank(accName)) {
                    match = existingByName.get(accName.toLowerCase());
                }
            }

            if (match != null) {
                if (matchedIds.contains(match.Id)) continue;
                matchedIds.add(match.Id);

                Account updateAcc = new Account(Id = match.Id);
                updateAcc.put('faxa__QuickBooks_Customer_Id__c', qbId);

                Map<String, Object> newFields = a.getPopulatedFieldsAsMap();
                for (String fld : newFields.keySet()) {
                    if (fld.equalsIgnoreCase('Id') || fld.equalsIgnoreCase('faxa__QuickBooks_Customer_Id__c')) continue;
                    if (fld.equalsIgnoreCase('Name')) { updateAcc.put(fld, newFields.get(fld)); continue; }
                    Object newVal = newFields.get(fld);
                    if (newVal == null) continue;
                    Object existingVal;
                    try {
                        existingVal = match.get(fld);
                    } catch (Exception e) {
                        updateAcc.put(fld, newVal);
                        continue;
                    }
                    if (existingVal == null || (existingVal instanceof String && String.isBlank((String) existingVal))) {
                        updateAcc.put(fld, newVal);
                    }
                }
                toUpdateMap.put(match.Id, updateAcc);
            } else {
                toInsert.add(a);
            }
        }
        List<Account> toUpdate = toUpdateMap.values();

        Integer successCount = 0;
        Integer failCount = 0;
        String errorDetails = '';
        List<Account> retryAccounts = new List<Account>();

        if (!toInsert.isEmpty()) {
            List<Database.SaveResult> insertResults = Database.insert(toInsert, dmlOpts);
            for (Integer i = 0; i < insertResults.size(); i++) {
                if (insertResults[i].isSuccess()) {
                    successCount++;
                } else {
                    Boolean isStateError = false;
                    for (Database.Error e : insertResults[i].getErrors()) {
                        Set<String> errFields = new Set<String>(e.getFields());
                        if (e.getStatusCode() == StatusCode.FIELD_INTEGRITY_EXCEPTION &&
                            (errFields.contains('BillingState') || errFields.contains('ShippingState') ||
                             errFields.contains('BillingStateCode') || errFields.contains('ShippingStateCode') ||
                             errFields.contains('BillingCountry') || errFields.contains('ShippingCountry') ||
                             errFields.contains('BillingCountryCode') || errFields.contains('ShippingCountryCode'))) {
                            isStateError = true;
                        }
                    }
                    if (isStateError) {
                        Account retry = toInsert[i].clone(false, true);
                        retry.put('BillingState', null);
                        retry.put('ShippingState', null);
                        retry.put('BillingCountryCode', null);
                        retry.put('ShippingCountryCode', null);
                        retry.put('BillingCity', null);
                        retry.put('ShippingCity', null);
                        retry.put('BillingPostalCode', null);
                        retry.put('ShippingPostalCode', null);
                        retry.put('BillingStreet', null);
                        retry.put('ShippingStreet', null);
                        retryAccounts.add(retry);
                    } else {
                        failCount++;
                        for (Database.Error e : insertResults[i].getErrors()) {
                            errorDetails += 'Insert Row ' + i + ': ' + e.getStatusCode() + ' - ' + e.getMessage() + ' Fields: ' + e.getFields() + '\n';
                        }
                    }
                }
            }
        }

        if (!toUpdate.isEmpty()) {
            List<Database.SaveResult> updateResults = Database.update(toUpdate, false);
            for (Integer i = 0; i < updateResults.size(); i++) {
                if (updateResults[i].isSuccess()) {
                    successCount++;
                } else {
                    Boolean isStateError = false;
                    for (Database.Error e : updateResults[i].getErrors()) {
                        Set<String> errFields = new Set<String>(e.getFields());
                        if (e.getStatusCode() == StatusCode.FIELD_INTEGRITY_EXCEPTION &&
                            (errFields.contains('BillingState') || errFields.contains('ShippingState') ||
                             errFields.contains('BillingStateCode') || errFields.contains('ShippingStateCode') ||
                             errFields.contains('BillingCountry') || errFields.contains('ShippingCountry') ||
                             errFields.contains('BillingCountryCode') || errFields.contains('ShippingCountryCode'))) {
                            isStateError = true;
                        }
                    }
                    if (isStateError) {
                        Account retry = toUpdate[i].clone(true, true);
                        retry.put('BillingState', null);
                        retry.put('ShippingState', null);
                        retry.put('BillingCountryCode', null);
                        retry.put('ShippingCountryCode', null);
                        retry.put('BillingCity', null);
                        retry.put('ShippingCity', null);
                        retry.put('BillingPostalCode', null);
                        retry.put('ShippingPostalCode', null);
                        retry.put('BillingStreet', null);
                        retry.put('ShippingStreet', null);
                        retryAccounts.add(retry);
                    } else {
                        failCount++;
                        for (Database.Error e : updateResults[i].getErrors()) {
                            errorDetails += 'Update Row ' + i + ': ' + e.getStatusCode() + ' - ' + e.getMessage() + ' Fields: ' + e.getFields() + '\n';
                        }
                    }
                }
            }
        }

        if (!retryAccounts.isEmpty()) {
            List<Account> retryInserts = new List<Account>();
            List<Account> retryUpdates = new List<Account>();
            for (Account r : retryAccounts) {
                if (r.Id != null) {
                    retryUpdates.add(r);
                } else {
                    retryInserts.add(r);
                }
            }
            if (!retryInserts.isEmpty()) {
                for (Database.SaveResult sr : Database.insert(retryInserts, dmlOpts)) {
                    if (sr.isSuccess()) { successCount++; } else {
                        failCount++;
                        for (Database.Error e : sr.getErrors()) {
                            errorDetails += 'Retry Insert: ' + e.getStatusCode() + ' - ' + e.getMessage() + ' Fields: ' + e.getFields() + '\n';
                        }
                    }
                }
            }
            if (!retryUpdates.isEmpty()) {
                for (Database.SaveResult sr : Database.update(retryUpdates, false)) {
                    if (sr.isSuccess()) { successCount++; } else {
                        failCount++;
                        for (Database.Error e : sr.getErrors()) {
                            errorDetails += 'Retry Update: ' + e.getStatusCode() + ' - ' + e.getMessage() + ' Fields: ' + e.getFields() + '\n';
                        }
                    }
                }
            }
        }

        System.debug('Upsert Results - Success: ' + successCount + ', Failed: ' + failCount);
        if (String.isNotBlank(errorDetails)) {
            System.debug('Upsert Errors:\n' + errorDetails);
        }

        faxa__External_App_Request_Log__c log = new faxa__External_App_Request_Log__c(
            faxa__Status__c = failCount == 0 ? 'Success' : 'Partial',
            faxa__QB_Http_Request__c = req.Id
        );
        if (String.isNotBlank(errorDetails)) {
            log.faxa__Error_Message__c = errorDetails.abbreviate(32768);
        }
        insert log;
    }

    // ================= DYNAMIC MAPPING =================
    private Account mapDynamic(Map<String, Object> qb) {

        if (qb == null) return null;

        Account acc = new Account();
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Account.fields.getMap();

        for (faxa__Mapping__c m : mappings) {

            String sfField = m.faxa__FieldAx_Field__c;
            String qbPath  = m.faxa__External_App_Field__c;

            Schema.SObjectField fieldToken = fieldMap.get(sfField);
            if (fieldToken == null) continue;

            Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
            if (!dfr.isUpdateable()) {
                if (sfField.equalsIgnoreCase('Tax_Code_Id__c')) {
                    Object taxVal = getNested(qb, qbPath);
                    if (taxVal != null) {
                        Id taxId = taxCodeMap.get(String.valueOf(taxVal));
                        if (taxId != null) {
                            acc.put('Tax_Group_Code__c', taxId);
                        }
                    }
                }
                continue;
            }

            Object val = getNested(qb, qbPath);

            if (val == null) {
                if (dfr.getType() == Schema.DisplayType.PICKLIST && qbPath.endsWith('.value')) {
                    String namePath = qbPath.removeEnd('.value') + '.name';
                    val = getNested(qb, namePath);
                }
                if (val == null) continue;
            }

            if (dfr.getType() == Schema.DisplayType.PICKLIST && qbPath.endsWith('.value')) {
                String namePath = qbPath.removeEnd('.value') + '.name';
                Object nameVal = getNested(qb, namePath);
                if (nameVal != null) val = nameVal;
            }

            try {
                if (dfr.getType() == Schema.DisplayType.REFERENCE) {
                    List<Schema.SObjectType> refs = dfr.getReferenceTo();
                    if (!refs.isEmpty() && refs[0].getDescribe().getName() == 'faxa__Tax__c') {
                        String taxKey = String.valueOf(val);
                        Id taxId = taxCodeMap.get(taxKey);
                        if (taxId != null) {
                            acc.put(sfField, taxId);
                        }
                        continue;
                    }
                }

                String sfLower = sfField.toLowerCase();
                if (sfLower == 'billingcountry' || sfLower == 'shippingcountry') {
                    String code = normalizeCountry(String.valueOf(val));
                    if (code != null) {
                        String codeField = sfLower == 'billingcountry' ? 'BillingCountryCode' : 'ShippingCountryCode';
                        acc.put(codeField, code);
                    }
                    continue;
                }

                String strVal = String.valueOf(val);
                if (dfr.getType() == Schema.DisplayType.EMAIL && strVal.contains(',')) {
                    strVal = strVal.split(',')[0].trim();
                }
                if (dfr.getType() == Schema.DisplayType.PHONE && strVal.length() > 21) {
                    strVal = strVal.left(21);
                }
                if (dfr.getType() == Schema.DisplayType.STRING && strVal.length() > dfr.getLength()) {
                    strVal = strVal.left(dfr.getLength());
                }

                acc.put(sfField, strVal);
            } catch (Exception e) {
                System.debug('Mapping error for ' + sfField + ': ' + e.getMessage());
            }
        }

        acc.put('faxa__QuickBooks_Customer_Id__c', String.valueOf(qb.get('Id')));

        if (acc.get('BillingState') != null && acc.get('BillingCountryCode') == null) {
            acc.put('BillingCountryCode', 'US');
        }
        if (acc.get('ShippingState') != null && acc.get('ShippingCountryCode') == null) {
            acc.put('ShippingCountryCode', 'US');
        }

        return acc;
    }

    // ================= COUNTRY NORMALIZATION =================
    private static final Map<String, String> COUNTRY_MAP = new Map<String, String>{
        'US' => 'US', 'USA' => 'US', 'UNITED STATES' => 'US', 'UNITED STATES OF AMERICA' => 'US', 'U.S.' => 'US', 'U.S.A.' => 'US',
        'CA' => 'CA', 'CANADA' => 'CA',
        'IN' => 'IN', 'INDIA' => 'IN',
        'GB' => 'GB', 'UK' => 'GB', 'UNITED KINGDOM' => 'GB', 'GREAT BRITAIN' => 'GB', 'ENGLAND' => 'GB',
        'AU' => 'AU', 'AUSTRALIA' => 'AU',
        'MX' => 'MX', 'MEXICO' => 'MX',
        'DE' => 'DE', 'GERMANY' => 'DE',
        'FR' => 'FR', 'FRANCE' => 'FR',
        'JP' => 'JP', 'JAPAN' => 'JP',
        'CN' => 'CN', 'CHINA' => 'CN',
        'BR' => 'BR', 'BRAZIL' => 'BR',
        'NZ' => 'NZ', 'NEW ZEALAND' => 'NZ',
        'SG' => 'SG', 'SINGAPORE' => 'SG',
        'AE' => 'AE', 'UAE' => 'AE', 'UNITED ARAB EMIRATES' => 'AE'
    };

    private String normalizeCountry(String raw) {
        if (String.isBlank(raw)) return null;
        String key = raw.trim().toUpperCase();
        if (COUNTRY_MAP.containsKey(key)) return COUNTRY_MAP.get(key);
        if (key.length() == 2) return key;
        return null;
    }

    // ================= NESTED JSON =================
    private Object getNested(Map<String, Object> data, String path) {

        List<String> parts = path.split('\\.');
        Object current = data;

        for (String p : parts) {

            if (!(current instanceof Map<String, Object>)) return null;

            current = ((Map<String, Object>) current).get(p);
        }

        return current;
    }

    // ================= CALLOUT =================
    private HttpResponse callQB(String endpoint) {

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Accept', 'application/json');

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() == 401) {
            if (refreshAccessToken()) {
                req.setHeader('Authorization', 'Bearer ' + accessToken);
                res = new Http().send(req);
            }
        }

        return res;
    }

    // ================= TOKEN REFRESH =================
    private Boolean refreshAccessToken() {

        HttpRequest req = new HttpRequest();
        req.setEndpoint(TOKEN_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setHeader('Accept', 'application/json');

        String credentials = EncodingUtil.base64Encode(
            Blob.valueOf(clientId + ':' + clientSecret)
        );
        req.setHeader('Authorization', 'Basic ' + credentials);

        req.setBody('grant_type=refresh_token&refresh_token=' +
                     EncodingUtil.urlEncode(refreshToken, 'UTF-8'));

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() == 200) {
            Map<String, Object> tokenData =
                (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

            accessToken = (String) tokenData.get('access_token');

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
        }

        System.debug('Token refresh failed: HTTP ' + res.getStatusCode() + ' - ' + res.getBody());
        return false;
    }

    // ================= FINISH =================
    public void finish(Database.BatchableContext bc) {

        // Save refreshed token if used
        if (pendingTokenUpdate != null) {
            update pendingTokenUpdate;
        }

        System.debug('QuickBooks Sync Completed');
    }

    // ================= PAGE RESULT =================
    private class PageResult {
        String endpoint;
        HttpResponse res;
        String responseBody;
        List<Object> customers;
    }

    // ================= EXCEPTION =================
    public class BatchException extends Exception {}
}