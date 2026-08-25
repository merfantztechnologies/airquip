@IsTest
private class QuickBooksVendorFromQBSyncBatchFixedTest {

    private static final String QB_VENDOR_RESPONSE = '{"QueryResponse":{"Vendor":[' +
        '{"Id":"501","DisplayName":"Vendor Alpha",' +
        '"PrimaryPhone":{"FreeFormNumber":"555-0001"},' +
        '"TermRef":{"value":"5","name":"NET 10"},' +
        '"BillAddr":{"Line1":"10 Vendor Rd","City":"Austin","CountrySubDivisionCode":"TX","Country":"US","PostalCode":"78701"},' +
        '"DefaultTaxCodeRef":{"value":"TAX001"}},' +
        '{"Id":"502","DisplayName":"Vendor Beta",' +
        '"PrimaryPhone":{"FreeFormNumber":"555-0002"},' +
        '"TermRef":{"value":"3","name":"NET 30"},' +
        '"BillAddr":{"Line1":"20 Supply Ln","City":"Dallas","CountrySubDivisionCode":"TX","Country":"US","PostalCode":"75001"}}' +
        ']}}';

    private static final String QB_EMPTY_RESPONSE = '{"QueryResponse":{}}';

    private static final String QB_FULL_PAGE_TEMPLATE_START = '{"QueryResponse":{"Vendor":[';
    private static final String QB_FULL_PAGE_TEMPLATE_END = ']}}';

    private static Account vendorAccount(String name, String qbVendorId) {
        Account a = new Account(
            Name = name,
            faxa__Account_Type__c = 'Vendor',
            BillingStreet = '100 Test St',
            BillingCity = 'Austin',
            BillingStateCode = 'TX',
            BillingPostalCode = '78701',
            BillingCountryCode = 'US',
            ShippingStreet = '100 Test St',
            ShippingCity = 'Austin',
            ShippingStateCode = 'TX',
            ShippingPostalCode = '78701',
            ShippingCountryCode = 'US'
        );
        if (String.isNotBlank(qbVendorId)) {
            a.faxa__QuickBooks_Vendor_Id__c = qbVendorId;
        }
        return a;
    }

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

        List<faxa__Mapping__c> mappings = new List<faxa__Mapping__c>{
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'Account',
                faxa__External_Object__c = 'Vendor',
                faxa__FieldAx_Field__c = 'Name',
                faxa__External_App_Field__c = 'DisplayName'
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'Account',
                faxa__External_Object__c = 'Vendor',
                faxa__FieldAx_Field__c = 'Phone',
                faxa__External_App_Field__c = 'PrimaryPhone.FreeFormNumber'
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'Account',
                faxa__External_Object__c = 'Vendor',
                faxa__FieldAx_Field__c = 'BillingStreet',
                faxa__External_App_Field__c = 'BillAddr.Line1'
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'Account',
                faxa__External_Object__c = 'Vendor',
                faxa__FieldAx_Field__c = 'BillingCity',
                faxa__External_App_Field__c = 'BillAddr.City'
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'Account',
                faxa__External_Object__c = 'Vendor',
                faxa__FieldAx_Field__c = 'BillingState',
                faxa__External_App_Field__c = 'BillAddr.CountrySubDivisionCode'
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'Account',
                faxa__External_Object__c = 'Vendor',
                faxa__FieldAx_Field__c = 'BillingPostalCode',
                faxa__External_App_Field__c = 'BillAddr.PostalCode'
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'Account',
                faxa__External_Object__c = 'Vendor',
                faxa__FieldAx_Field__c = 'BillingCountry',
                faxa__External_App_Field__c = 'BillAddr.Country'
            ),
            new faxa__Mapping__c(
                faxa__External_App__c = app.Id,
                faxa__FieldAx_Object__c = 'Account',
                faxa__External_Object__c = 'Vendor',
                faxa__FieldAx_Field__c = 'Terms__c',
                faxa__External_App_Field__c = 'SalesTermRef.name'
            )
        };
        insert mappings;

        insert new faxa__Tax__c(faxa__Tax_Code_Id__c = 'TAX001');
    }

    private class SuccessMock implements HttpCalloutMock {
        private Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            // First call = full page (50) to exercise continuation queueing
            if (callCount == 1) {
                List<String> rows = new List<String>();
                for (Integer i = 1; i <= 50; i++) {
                    rows.add(
                        '{"Id":"' + (600 + i) + '","DisplayName":"Bulk Vendor ' + i + '",'
                        + '"BillAddr":{"Line1":"' + i + ' Main","City":"Austin","CountrySubDivisionCode":"TX","Country":"US","PostalCode":"78701"}}'
                    );
                }
                res.setBody(QB_FULL_PAGE_TEMPLATE_START + String.join(rows, ',') + QB_FULL_PAGE_TEMPLATE_END);
                return res;
            }
            res.setBody(QB_EMPTY_RESPONSE);
            return res;
        }
    }

    private class SimpleSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(QB_VENDOR_RESPONSE);
            return res;
        }
    }

    private class FailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"Fault":{"Error":[{"Message":"server error"}]}}');
            return res;
        }
    }

    private class EmptyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(QB_EMPTY_RESPONSE);
            return res;
        }
    }

    private class TokenThenSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint() != null && req.getEndpoint().contains('oauth2/v1/tokens/bearer')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"new_token","refresh_token":"new_refresh","expires_in":3600}');
                return res;
            }
            if (req.getHeader('Authorization') == 'Bearer mock_access_token') {
                res.setStatusCode(401);
                res.setBody('{"error":"invalid_token"}');
                return res;
            }
            res.setStatusCode(200);
            res.setBody(QB_VENDOR_RESPONSE);
            return res;
        }
    }

    @IsTest
    static void testSuccessfulVendorSync() {
        Test.setMock(HttpCalloutMock.class, new SimpleSuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        List<Account> accounts = [
            SELECT Name, Phone, BillingStreet, BillingCity, BillingPostalCode,
                   faxa__QuickBooks_Vendor_Id__c, faxa__Account_Type__c, Terms__c
            FROM Account
            WHERE faxa__QuickBooks_Vendor_Id__c IN ('501', '502')
            ORDER BY faxa__QuickBooks_Vendor_Id__c
        ];
        System.assertEquals(2, accounts.size(), 'Should upsert 2 vendor accounts');
        System.assertEquals('Vendor Alpha', accounts[0].Name);
        System.assertEquals('555-0001', accounts[0].Phone);
        System.assertEquals('10 Vendor Rd', accounts[0].BillingStreet);
        System.assertEquals('Austin', accounts[0].BillingCity);
        System.assertEquals('78701', accounts[0].BillingPostalCode);
        System.assertEquals('Vendor', accounts[0].faxa__Account_Type__c);
        System.assertEquals('NET 10', accounts[0].Terms__c, 'Terms should sync from TermRef.name');
        System.assertEquals('Vendor Beta', accounts[1].Name);
        System.assertEquals('NET 30', accounts[1].Terms__c);

        System.assert(![SELECT Id FROM faxa__External_App_Request__c].isEmpty(), 'Request audit expected');
        System.assert(![SELECT Id FROM faxa__External_App_Request_Log__c].isEmpty(), 'Log audit expected');
    }

    @IsTest
    static void testUpdatesExistingByQbVendorId() {
        insert vendorAccount('Old Vendor Name', '501');

        Test.setMock(HttpCalloutMock.class, new SimpleSuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        Account updated = [
            SELECT Name, Phone FROM Account WHERE faxa__QuickBooks_Vendor_Id__c = '501'
        ];
        System.assertEquals('Vendor Alpha', updated.Name);
        System.assertEquals('555-0001', updated.Phone);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Account WHERE faxa__QuickBooks_Vendor_Id__c = '501'],
            'Should update existing, not duplicate'
        );
    }

    @IsTest
    static void testMatchesByNameWhenVendorIdBlank() {
        insert vendorAccount('Vendor Alpha', null);

        Test.setMock(HttpCalloutMock.class, new SimpleSuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        Account linked = [
            SELECT faxa__QuickBooks_Vendor_Id__c, Phone
            FROM Account
            WHERE Name = 'Vendor Alpha'
            LIMIT 1
        ];
        System.assertEquals('501', linked.faxa__QuickBooks_Vendor_Id__c);
        System.assertEquals('555-0001', linked.Phone);
    }

    @IsTest
    static void testCalloutFailure() {
        Test.setMock(HttpCalloutMock.class, new FailMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        List<faxa__External_App_Request_Log__c> logs = [
            SELECT faxa__Status__c FROM faxa__External_App_Request_Log__c
            WHERE faxa__Status__c LIKE 'Failed%'
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals(
            0,
            [SELECT COUNT() FROM Account WHERE faxa__QuickBooks_Vendor_Id__c != null]
        );
    }

    @IsTest
    static void testEmptyResponse() {
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM Account WHERE faxa__QuickBooks_Vendor_Id__c != null]
        );
    }

    @IsTest
    static void testTokenRefreshAndContinuationPage() {
        Test.setMock(HttpCalloutMock.class, new TokenThenSuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(1, false), 1);
        Test.stopTest();

        System.assert(
            [SELECT COUNT() FROM Account WHERE faxa__QuickBooks_Vendor_Id__c IN ('501', '502')] >= 1,
            'Should sync after token refresh'
        );
    }

    @IsTest
    static void testFullPageChainsContinuation() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(1, false), 1);
        Test.stopTest();

        System.assert(
            [SELECT COUNT() FROM Account WHERE faxa__QuickBooks_Vendor_Id__c LIKE '6%'] >= 1,
            'Full page should insert bulk vendors'
        );
    }

    @IsTest
    static void testSchedulableAndConstructors() {
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        Test.startTest();
        String jobId = System.schedule(
            'QB Vendor Fixed Test ' + Datetime.now().getTime(),
            '0 0 6 * * ?',
            new QuickBooksVendorFromQBSyncBatchFixed()
        );
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(true), 1);
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(2), 1);
        Test.stopTest();

        System.assertNotEquals(null, jobId);
    }

    @IsTest
    static void testAuthFailureInStart() {
        faxa__External_App__c app = [
            SELECT Id FROM faxa__External_App__c WHERE Name = 'QuickBook' LIMIT 1
        ];
        app.faxa__Authentication_Status__c = 'Failed';
        update app;

        Boolean threw = false;
        try {
            Test.startTest();
            Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
            Test.stopTest();
        } catch (Exception e) {
            threw = e.getMessage() != null && e.getMessage().contains('not authenticated');
        }
        System.assert(threw, 'Unauthenticated app should fail start');
    }

    @IsTest
    static void testVendorCreateWithCountryTypo() {
        // Country typo "Unitd States" must still create (QB Id 2603 style)
        String body = '{"QueryResponse":{"Vendor":[{'
            + '"Id":"2603","CompanyName":"Elite Pune Distribution Group","DisplayName":"Elite Pune Distribution Group",'
            + '"PrimaryPhone":{"FreeFormNumber":"+91 9302529557"},'
            + '"BillAddr":{"Line1":"503, Highland Road","City":"Chicago","Country":"Unitd States",'
            + '"CountrySubDivisionCode":"Illinois","PostalCode":"60601"}'
            + '}]}}';
        Test.setMock(HttpCalloutMock.class, new FixedBodyMock(body));

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        List<Account> created = [
            SELECT Name, BillingStreet, BillingCity, BillingStateCode, BillingCountryCode,
                   ShippingStreet, ShippingCountryCode, Phone, faxa__QuickBooks_Vendor_Id__c
            FROM Account
            WHERE faxa__QuickBooks_Vendor_Id__c = '2603'
        ];
        System.assertEquals(1, created.size(), 'Typo country Unitd States should still insert');
        System.assertEquals('Elite Pune Distribution Group', created[0].Name);
        System.assertEquals('503, Highland Road', created[0].BillingStreet);
        System.assertEquals('Chicago', created[0].BillingCity);
        System.assertEquals('IL', created[0].BillingStateCode);
        System.assertEquals('US', created[0].BillingCountryCode);
        System.assertEquals('US', created[0].ShippingCountryCode);
        System.assertNotEquals(null, created[0].ShippingStreet);
    }

    @IsTest
    static void testVendorUpdateFromQuickBooks() {
        Account existing = new Account(
            Name = 'Elite Pune Distribution Group',
            faxa__Account_Type__c = 'Vendor',
            faxa__QuickBooks_Vendor_Id__c = '2603',
            Phone = '111',
            BillingStreet = 'Old St', BillingCity = 'Chicago', BillingStateCode = 'IL',
            BillingPostalCode = '60601', BillingCountryCode = 'US',
            ShippingStreet = 'Old St', ShippingCity = 'Chicago', ShippingStateCode = 'IL',
            ShippingPostalCode = '60601', ShippingCountryCode = 'US'
        );
        insert existing;

        String body = '{"QueryResponse":{"Vendor":[{'
            + '"Id":"2603","CompanyName":"Elite Pune Distribution Group","DisplayName":"Elite Pune Distribution Group",'
            + '"PrimaryPhone":{"FreeFormNumber":"555-000-1111"},'
            + '"BillAddr":{"Line1":"999 Updated Ave","City":"Chicago","Country":"United States",'
            + '"CountrySubDivisionCode":"IL","PostalCode":"60601"}'
            + '}]}}';
        Test.setMock(HttpCalloutMock.class, new FixedBodyMock(body));

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        Account updated = [
            SELECT Phone, BillingStreet FROM Account WHERE Id = :existing.Id
        ];
        System.assertEquals('555-000-1111', updated.Phone);
        System.assertEquals('999 Updated Ave', updated.BillingStreet);
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE faxa__QuickBooks_Vendor_Id__c = '2603']);
    }

    @IsTest
    static void testDefaultMappingWithoutVendorMappings() {
        delete [SELECT Id FROM faxa__Mapping__c];

        String body = '{"QueryResponse":{"Vendor":[{'
            + '"Id":"701","DisplayName":"Company Only Vendor",'
            + '"PrimaryPhone":{"FreeFormNumber":"555-9999"},'
            + '"BillAddr":{"Line1":"9 Default St","City":"Houston","CountrySubDivisionCode":"TX","Country":"US","PostalCode":"77002"},'
            + '"ShipAddr":{"Line1":"9 Ship St","City":"Houston","CountrySubDivisionCode":"TX","Country":"US","PostalCode":"77002"}'
            + '}]}}';

        Test.setMock(HttpCalloutMock.class, new FixedBodyMock(body));

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        List<Account> created = [
            SELECT Name, Phone, BillingStreet, ShippingStreet, faxa__QuickBooks_Vendor_Id__c
            FROM Account
            WHERE faxa__QuickBooks_Vendor_Id__c = '701'
        ];
        System.assertEquals(
            1,
            created.size(),
            'Expected default-mapped vendor. Logs=' +
            JSON.serialize([SELECT faxa__Status__c, faxa__Error_Message__c FROM faxa__External_App_Request_Log__c])
        );
        System.assertEquals('Company Only Vendor', created[0].Name);
        System.assertEquals('9 Default St', created[0].BillingStreet);
        System.assertEquals('9 Ship St', created[0].ShippingStreet);
    }

    @IsTest
    static void testInvalidJsonResponse() {
        Test.setMock(HttpCalloutMock.class, new FixedBodyMock('not-json', 200));

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        System.assert(
            [SELECT COUNT() FROM faxa__External_App_Request_Log__c WHERE faxa__Status__c LIKE 'Failed%'] >= 1
        );
    }

    @IsTest
    static void testBlankResponseBody() {
        Test.setMock(HttpCalloutMock.class, new FixedBodyMock('', 200));

        Test.startTest();
        Database.executeBatch(new QuickBooksVendorFromQBSyncBatchFixed(false), 1);
        Test.stopTest();

        System.assert(
            [SELECT COUNT() FROM faxa__External_App_Request_Log__c WHERE faxa__Status__c LIKE 'Failed%'] >= 1
        );
    }

    private class FixedBodyMock implements HttpCalloutMock {
        private String body;
        private Integer statusCode;
        FixedBodyMock(String body) {
            this(body, 200);
        }
        FixedBodyMock(String body, Integer statusCode) {
            this.body = body;
            this.statusCode = statusCode;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body == null ? '' : body);
            return res;
        }
    }
}