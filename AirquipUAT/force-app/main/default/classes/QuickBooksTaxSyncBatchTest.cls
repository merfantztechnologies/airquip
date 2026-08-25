@IsTest
private class QuickBooksTaxSyncBatchTest {

    private static final String TAX_RATE_RESPONSE = '{"QueryResponse":{"TaxRate":[' +
        '{"Id":"1","Name":"GST 10%","RateValue":10},' +
        '{"Id":"2","Name":"PST 5%","RateValue":5},' +
        '{"Id":"3","Name":"Zero Rate","RateValue":0}' +
        ']}}';

    private static final String TAX_CODE_RESPONSE = '{"QueryResponse":{"TaxCode":[' +
        '{"Id":"100","Name":"GST Only","Active":true,"TaxCodeConfigType":"USER_DEFINED",' +
        '"SalesTaxRateList":{"TaxRateDetail":[{"TaxRateRef":{"value":"1"}}]}},' +
        '{"Id":"200","Name":"GST+PST Combined","Active":true,"TaxCodeConfigType":"USER_DEFINED",' +
        '"SalesTaxRateList":{"TaxRateDetail":[{"TaxRateRef":{"value":"1"}},{"TaxRateRef":{"value":"2"}}]}},' +
        '{"Id":"300","Name":"Zero Rated","Active":false,"TaxCodeConfigType":"USER_DEFINED",' +
        '"SalesTaxRateList":{"TaxRateDetail":[{"TaxRateRef":{"value":"3"}}]}},' +
        '{"Id":"999","Name":"System Code","Active":true,"TaxCodeConfigType":"TAX_CODE_INCOME_TAXABLE"}' +
        ']}}';

    private static final String EMPTY_RESPONSE = '{"QueryResponse":{}}';

    @TestSetup
    static void setup() {
        faxa__External_App__c app = new faxa__External_App__c(
            Name = 'QuickBook',
            faxa__Realm_ID__c = '1234567890',
            faxa__Access_Token__c = 'mock_access_token',
            faxa__Refresh_Token__c = 'mock_refresh_token',
            faxa__Client_Id__c = 'mock_client_id',
            faxa__Client_Secret__c = 'mock_client_secret',
            faxa__Authentication_Status__c = 'Successful'
        );
        insert app;

        Account acc = new Account(Name = 'Dummy Account');
        insert acc;
    }

    private class TaxSyncMock implements HttpCalloutMock {
        private String taxRateBody;
        private String taxCodeBody;

        TaxSyncMock(String taxRateBody, String taxCodeBody) {
            this.taxRateBody = taxRateBody;
            this.taxCodeBody = taxCodeBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);

            if (req.getEndpoint().contains('TaxRate')) {
                res.setBody(this.taxRateBody);
            } else if (req.getEndpoint().contains('TaxCode')) {
                res.setBody(this.taxCodeBody);
            } else {
                res.setBody(EMPTY_RESPONSE);
            }
            return res;
        }
    }

    private class FailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setBody('{"error":"invalid_token"}');
            return res;
        }
    }

    @IsTest
    static void testSuccessfulInsert() {
        Test.setMock(HttpCalloutMock.class, new TaxSyncMock(TAX_RATE_RESPONSE, TAX_CODE_RESPONSE));

        Test.startTest();
        Database.executeBatch(new QuickBooksTaxSyncBatch(), 1);
        Test.stopTest();

        List<faxa__Tax__c> taxes = [
            SELECT Name, faxa__Tax_Code_Id__c, faxa__Tax_Rate_Id__c,
                   faxa__Active__c, faxa__Percentage__c
            FROM faxa__Tax__c
            ORDER BY faxa__Tax_Code_Id__c
        ];

        System.assertEquals(3, taxes.size(), 'Should insert 3 USER_DEFINED tax codes');

        faxa__Tax__c gstOnly = taxes[0];
        System.assertEquals('GST Only', gstOnly.Name);
        System.assertEquals('100', gstOnly.faxa__Tax_Code_Id__c);
        System.assertEquals('1', gstOnly.faxa__Tax_Rate_Id__c);
        System.assertEquals(true, gstOnly.faxa__Active__c);
        System.assertEquals(10, gstOnly.faxa__Percentage__c);

        faxa__Tax__c combined = taxes[1];
        System.assertEquals('GST+PST Combined', combined.Name);
        System.assertEquals('200', combined.faxa__Tax_Code_Id__c);
        System.assertEquals('1,2', combined.faxa__Tax_Rate_Id__c);
        System.assertEquals(15, combined.faxa__Percentage__c);

        faxa__Tax__c zero = taxes[2];
        System.assertEquals('Zero Rated', zero.Name);
        System.assertEquals(false, zero.faxa__Active__c);
        System.assertEquals(0, zero.faxa__Percentage__c);
    }

    @IsTest
    static void testUpdateExistingTax() {
        faxa__Tax__c existing = new faxa__Tax__c(
            Name = 'Old Name',
            faxa__Tax_Code_Id__c = '100',
            faxa__Percentage__c = 5
        );
        insert existing;

        Test.setMock(HttpCalloutMock.class, new TaxSyncMock(TAX_RATE_RESPONSE, TAX_CODE_RESPONSE));

        Test.startTest();
        Database.executeBatch(new QuickBooksTaxSyncBatch(), 1);
        Test.stopTest();

        faxa__Tax__c updated = [
            SELECT Name, faxa__Percentage__c, faxa__Active__c
            FROM faxa__Tax__c
            WHERE faxa__Tax_Code_Id__c = '100'
        ];
        System.assertEquals('GST Only', updated.Name, 'Name should be updated');
        System.assertEquals(10, updated.faxa__Percentage__c, 'Percentage should be updated');
        System.assertEquals(true, updated.faxa__Active__c, 'Active should be updated');

        Integer total = [SELECT COUNT() FROM faxa__Tax__c WHERE faxa__Tax_Code_Id__c = '100'];
        System.assertEquals(1, total, 'Should not duplicate');
    }

    @IsTest
    static void testNoDeleteOfOrphanRecords() {
        faxa__Tax__c orphan = new faxa__Tax__c(
            Name = 'Orphan Tax',
            faxa__Tax_Code_Id__c = '999999'
        );
        insert orphan;

        Test.setMock(HttpCalloutMock.class, new TaxSyncMock(TAX_RATE_RESPONSE, TAX_CODE_RESPONSE));

        Test.startTest();
        Database.executeBatch(new QuickBooksTaxSyncBatch(), 1);
        Test.stopTest();

        List<faxa__Tax__c> orphans = [
            SELECT Id FROM faxa__Tax__c WHERE faxa__Tax_Code_Id__c = '999999'
        ];
        System.assertEquals(1, orphans.size(), 'Orphan record should NOT be deleted');
    }

    @IsTest
    static void testAuthNotSuccessfulEarlyReturn() {
        faxa__External_App__c app = [
            SELECT Id FROM faxa__External_App__c WHERE Name = 'QuickBook'
        ];
        app.faxa__Authentication_Status__c = 'Failed';
        update app;

        Test.setMock(HttpCalloutMock.class, new TaxSyncMock(TAX_RATE_RESPONSE, TAX_CODE_RESPONSE));

        Test.startTest();
        Database.executeBatch(new QuickBooksTaxSyncBatch(), 1);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM faxa__Tax__c];
        System.assertEquals(0, count, 'No tax records should be created when auth is not successful');
    }

    @IsTest
    static void testCalloutFailure() {
        Test.setMock(HttpCalloutMock.class, new FailMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksTaxSyncBatch(), 1);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM faxa__Tax__c];
        System.assertEquals(0, count, 'No tax records should be created on callout failure');
    }

    @IsTest
    static void testEmptyTaxCodeResponse() {
        Test.setMock(HttpCalloutMock.class, new TaxSyncMock(TAX_RATE_RESPONSE, EMPTY_RESPONSE));

        Test.startTest();
        Database.executeBatch(new QuickBooksTaxSyncBatch(), 1);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM faxa__Tax__c];
        System.assertEquals(0, count, 'No tax records should be created from empty response');
    }

    @IsTest
    static void testEmptyTaxRateResponse() {
        Test.setMock(HttpCalloutMock.class, new TaxSyncMock(EMPTY_RESPONSE, TAX_CODE_RESPONSE));

        Test.startTest();
        Database.executeBatch(new QuickBooksTaxSyncBatch(), 1);
        Test.stopTest();

        List<faxa__Tax__c> taxes = [
            SELECT faxa__Percentage__c FROM faxa__Tax__c
            WHERE faxa__Tax_Code_Id__c = '100'
        ];
        System.assertEquals(1, taxes.size(), 'Tax code should still be created');
        System.assertEquals(0, taxes[0].faxa__Percentage__c, 'Percentage should be 0 when tax rates are missing');
    }

    @IsTest
    static void testSkipsNonUserDefinedCodes() {
        Test.setMock(HttpCalloutMock.class, new TaxSyncMock(TAX_RATE_RESPONSE, TAX_CODE_RESPONSE));

        Test.startTest();
        Database.executeBatch(new QuickBooksTaxSyncBatch(), 1);
        Test.stopTest();

        List<faxa__Tax__c> systemCodes = [
            SELECT Id FROM faxa__Tax__c WHERE faxa__Tax_Code_Id__c = '999'
        ];
        System.assertEquals(0, systemCodes.size(), 'System-defined tax codes should be skipped');
    }
}