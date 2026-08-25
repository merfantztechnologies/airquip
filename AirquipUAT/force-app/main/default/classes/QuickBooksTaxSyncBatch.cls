global class QuickBooksTaxSyncBatch implements Database.Batchable<Object>, Database.AllowsCallouts {

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([SELECT Id FROM Account LIMIT 1]);
    }

    global void execute(Database.BatchableContext bc, List<Object> scope) {

        faxa__External_App__c app = [
            SELECT faxa__Realm_ID__c, faxa__Access_Token__c, faxa__Authentication_Status__c
            FROM faxa__External_App__c
            WHERE Name = 'QuickBook'
            LIMIT 1
        ];

        if (app.faxa__Authentication_Status__c != 'Successful') return;

        Boolean isSandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
        String baseUrl = isSandbox
            ? 'https://sandbox-quickbooks.api.intuit.com'
            : 'https://quickbooks.api.intuit.com';

        String realmId = app.faxa__Realm_ID__c;
        String token   = app.faxa__Access_Token__c;

        // ── STEP 1: TAX RATE MAP ────────────────────────────────────────
        Map<String, Decimal> taxRateMap = new Map<String, Decimal>();

        {
            String q = 'SELECT * FROM TaxRate MAXRESULTS 1000';

            HttpRequest r = new HttpRequest();
            r.setEndpoint(baseUrl + '/v3/company/' + realmId +
                          '/query?query=' + EncodingUtil.urlEncode(q, 'UTF-8'));
            r.setMethod('GET');
            r.setHeader('Authorization', 'Bearer ' + token);
            r.setHeader('Accept', 'application/json');

            HttpResponse res = new Http().send(r);

            if (res.getStatusCode() == 200) {
                Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                Map<String, Object> qr = (Map<String, Object>) root.get('QueryResponse');

                if (qr != null && qr.get('TaxRate') != null) {
                    for (Object o : (List<Object>) qr.get('TaxRate')) {
                        Map<String, Object> tr = (Map<String, Object>) o;

                        String id = String.valueOf(tr.get('Id'));
                        Decimal rate = tr.get('RateValue') != null
                            ? Decimal.valueOf(String.valueOf(tr.get('RateValue')))
                            : 0;

                        taxRateMap.put(id, rate);
                    }
                }
            }
        }

        // ── STEP 2: TAX CODES ───────────────────────────────────────────
        List<Object> taxCodes = new List<Object>();

        {
            String query = 'SELECT * FROM TaxCode MAXRESULTS 1000';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(baseUrl + '/v3/company/' + realmId +
                            '/query?query=' + EncodingUtil.urlEncode(query, 'UTF-8'));
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + token);
            req.setHeader('Accept', 'application/json');

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() == 200) {
                Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                Map<String, Object> qr = (Map<String, Object>) root.get('QueryResponse');

                if (qr != null && qr.get('TaxCode') != null) {
                    taxCodes = (List<Object>) qr.get('TaxCode');
                }
            }
        }

        // ── STEP 3: EXISTING ────────────────────────────────────────────
        Map<String, faxa__Tax__c> existingMap = new Map<String, faxa__Tax__c>();

        for (faxa__Tax__c t : [SELECT Id, Name, faxa__Tax_Code_Id__c FROM faxa__Tax__c]) {
            String key = String.isNotBlank(t.faxa__Tax_Code_Id__c)
                ? t.faxa__Tax_Code_Id__c.trim()
                : t.Name;
            if (String.isNotBlank(key)) {
                existingMap.put(key, t);
            }
        }

        // ── STEP 4: PROCESS ─────────────────────────────────────────────
        List<faxa__Tax__c> toInsert = new List<faxa__Tax__c>();
        List<faxa__Tax__c> toUpdate = new List<faxa__Tax__c>();

        for (Object o : taxCodes) {
            Map<String, Object> tc = (Map<String, Object>) o;

            if (String.valueOf(tc.get('TaxCodeConfigType')) != 'USER_DEFINED') continue;

            String id = String.valueOf(tc.get('Id')).trim();

            String name = tc.get('Name') != null ? String.valueOf(tc.get('Name')) : '';
            if (name.length() > 80) {
                name = name.substring(0, 80);
            }
            Boolean active = tc.get('Active') != null ? Boolean.valueOf(tc.get('Active')) : true;

            Decimal percentage = 0;
            List<String> taxRateIds = new List<String>();

            if (tc.get('SalesTaxRateList') != null) {
                Map<String, Object> rateList = (Map<String, Object>) tc.get('SalesTaxRateList');

                if (rateList.get('TaxRateDetail') != null) {
                    for (Object rd : (List<Object>) rateList.get('TaxRateDetail')) {
                        Map<String, Object> detail = (Map<String, Object>) rd;

                        if (detail.get('TaxRateRef') != null) {
                            Map<String, Object> ref = (Map<String, Object>) detail.get('TaxRateRef');
                            String rateId = String.valueOf(ref.get('value'));

                            if (String.isNotBlank(rateId) && !taxRateIds.contains(rateId)) {
                                taxRateIds.add(rateId);
                            }

                            if (taxRateMap.containsKey(rateId)) {
                                percentage += taxRateMap.get(rateId);
                            }
                        }
                    }
                }
            }

            String rateIdField = '';
            if (!taxRateIds.isEmpty()) {
                rateIdField = String.join(taxRateIds, ',');
                if (rateIdField.length() > 255) {
                    rateIdField = rateIdField.substring(0, 255);
                }
            }

            faxa__Tax__c rec = existingMap.containsKey(id)
                ? existingMap.get(id)
                : new faxa__Tax__c();

            rec.Name                    = name;
            rec.faxa__Tax_Code_Id__c    = id;
            rec.faxa__Tax_Rate_Id__c    = rateIdField;
            rec.faxa__Active__c         = active;
            rec.faxa__Percentage__c     = percentage;

            if (existingMap.containsKey(id)) {
                toUpdate.add(rec);
            } else {
                toInsert.add(rec);
            }
        }

        // ── STEP 5: DML ─────────────────────────────────────────────────
        if (!toInsert.isEmpty()) insert toInsert;
        if (!toUpdate.isEmpty()) update toUpdate;

        System.debug('Inserted: ' + toInsert.size() +
                     ' | Updated: ' + toUpdate.size());
    }

    global void finish(Database.BatchableContext bc) {
        System.debug('QuickBooks Tax Sync Completed');
    }
}