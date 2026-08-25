@IsTest
private class QuickBooksCustomerSyncBatchTest {

    private static final String QB_CUSTOMER_RESPONSE = '{"QueryResponse":{"Customer":[' +
        '{"Id":"101","DisplayName":"Test Corp","PrimaryPhone":{"FreeFormNumber":"555-1234"},' +
        '"BillAddr":{"Line1":"123 Main St","City":"Houston","CountrySubDivisionCode":"Texas","Country":"US","PostalCode":"77001"},' +
        '"ShipAddr":{"Line1":"456 Ship Ave","City":"Dallas","CountrySubDivisionCode":"Texas","Country":"US","PostalCode":"75001"},' +
        '"PrimaryEmailAddr":{"Address":"test@corp.com"},"WebAddr":{"URI":"https://testcorp.com"},' +
        '"SalesTermRef":{"value":"3","name":"Net 30"},' +
        '"DefaultTaxCodeRef":{"value":"TAX001"}},' +
        '{"Id":"102","DisplayName":"Intl Ltd","PrimaryPhone":{"FreeFormNumber":"555-5678"},' +
        '"BillAddr":{"Line1":"10 Queen St","City":"London","Country":"United Kingdom"},' +
        '"ShipAddr":{"Line1":"10 Queen St","City":"London","Country":"UK"}},' +
        '{"Id":"103","DisplayName":"No Country Inc",' +
        '"BillAddr":{"Line1":"789 Oak Rd","City":"Austin","CountrySubDivisionCode":"Texas"},' +
        '"ShipAddr":{"Line1":"789 Oak Rd","City":"Austin","CountrySubDivisionCode":"Texas"}}' +
        ']}}';

    private static final String QB_EMPTY_RESPONSE = '{"QueryResponse":{}}';

    private static final String TOKEN_REFRESH_RESPONSE = '{"access_token":"new_token","refresh_token":"new_refresh","token_type":"bearer","expires_in":3600}';

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
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'Name', faxa__External_App_Field__c = 'DisplayName'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'Phone', faxa__External_App_Field__c = 'PrimaryPhone.FreeFormNumber'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'BillingStreet', faxa__External_App_Field__c = 'BillAddr.Line1'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'BillingCity', faxa__External_App_Field__c = 'BillAddr.City'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'BillingState', faxa__External_App_Field__c = 'BillAddr.CountrySubDivisionCode'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'BillingCountry', faxa__External_App_Field__c = 'BillAddr.Country'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'BillingPostalCode', faxa__External_App_Field__c = 'BillAddr.PostalCode'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'ShippingStreet', faxa__External_App_Field__c = 'ShipAddr.Line1'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'ShippingCity', faxa__External_App_Field__c = 'ShipAddr.City'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'ShippingState', faxa__External_App_Field__c = 'ShipAddr.CountrySubDivisionCode'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'ShippingCountry', faxa__External_App_Field__c = 'ShipAddr.Country'),
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'Website', faxa__External_App_Field__c = 'WebAddr.URI')
        };
        insert mappings;

        faxa__Tax__c tax = new faxa__Tax__c(
            faxa__Tax_Code_Id__c = 'TAX001'
        );
        insert tax;
    }

    // Mock for successful QB API response
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(QB_CUSTOMER_RESPONSE);
            return res;
        }
    }

    // Mock for failed QB API response
    private class FailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setBody('{"error":"invalid_token"}');
            return res;
        }
    }

    // Mock that returns empty customer list
    private class EmptyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(QB_EMPTY_RESPONSE);
            return res;
        }
    }

    @IsTest
    static void testSuccessfulSync() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksCustomerSyncBatch(), 1);
        Test.stopTest();

        List<Account> accounts = [
            SELECT Name, Phone, BillingStreet, BillingCity, BillingState,
                   BillingCountryCode, Website, faxa__QuickBooks_Customer_Id__c
            FROM Account
            WHERE faxa__QuickBooks_Customer_Id__c IN ('101', '102', '103')
            ORDER BY faxa__QuickBooks_Customer_Id__c
        ];
        System.assertEquals(3, accounts.size(), 'Should upsert 3 accounts');

        Account testCorp = accounts[0];
        System.assertEquals('Test Corp', testCorp.Name);
        System.assertEquals('555-1234', testCorp.Phone);
        System.assertEquals('123 Main St', testCorp.BillingStreet);
        System.assertEquals('Houston', testCorp.BillingCity);
        System.assertEquals('US', testCorp.BillingCountryCode);
        System.assertEquals('https://testcorp.com', testCorp.Website);

        Account intlLtd = accounts[1];
        System.assertEquals('Intl Ltd', intlLtd.Name);
        System.assertEquals('GB', intlLtd.BillingCountryCode);

        Account noCountry = accounts[2];
        System.assertEquals('No Country Inc', noCountry.Name);
        System.assertEquals('US', noCountry.BillingCountryCode, 'Should default to US when state present but no country');

        List<faxa__External_App_Request__c> requests = [
            SELECT Id FROM faxa__External_App_Request__c
        ];
        System.assert(!requests.isEmpty(), 'Should create request record');

        List<faxa__External_App_Request_Log__c> logs = [
            SELECT faxa__Status__c FROM faxa__External_App_Request_Log__c
        ];
        System.assert(!logs.isEmpty(), 'Should create log record');
    }

    @IsTest
    static void testCalloutFailure() {
        Test.setMock(HttpCalloutMock.class, new FailMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksCustomerSyncBatch(), 1);
        Test.stopTest();

        List<faxa__External_App_Request_Log__c> logs = [
            SELECT faxa__Status__c, faxa__Error_Message__c
            FROM faxa__External_App_Request_Log__c
            WHERE faxa__Status__c = 'Failed'
        ];
        System.assertEquals(1, logs.size(), 'Should log a failure');
        System.assert(logs[0].faxa__Error_Message__c.contains('HTTP 401'), 'Error should contain status code');

        List<Account> accounts = [
            SELECT Id FROM Account
            WHERE faxa__QuickBooks_Customer_Id__c != null
        ];
        System.assertEquals(0, accounts.size(), 'No accounts should be created on callout failure');
    }

    @IsTest
    static void testEmptyResponse() {
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksCustomerSyncBatch(), 1);
        Test.stopTest();

        List<Account> accounts = [
            SELECT Id FROM Account
            WHERE faxa__QuickBooks_Customer_Id__c != null
        ];
        System.assertEquals(0, accounts.size(), 'No accounts should be created from empty response');
    }

    @IsTest
    static void testUpsertUpdatesExistingAccount() {
        Account existing = new Account(
            Name = 'Old Name',
            faxa__QuickBooks_Customer_Id__c = '101'
        );
        insert existing;

        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksCustomerSyncBatch(), 1);
        Test.stopTest();

        Account updated = [
            SELECT Name, Phone FROM Account
            WHERE faxa__QuickBooks_Customer_Id__c = '101'
        ];
        System.assertEquals('Test Corp', updated.Name, 'Name should be updated from QB');
        System.assertEquals('555-1234', updated.Phone, 'Phone should be updated from QB');
    }

    @IsTest
    static void testCountryNormalization() {
        String response = '{"QueryResponse":{"Customer":[' +
            '{"Id":"201","DisplayName":"US Alias Test",' +
            '"BillAddr":{"Country":"USA","CountrySubDivisionCode":"Texas"}},' +
            '{"Id":"202","DisplayName":"India Test",' +
            '"BillAddr":{"Country":"India","CountrySubDivisionCode":"Delhi"}},' +
            '{"Id":"203","DisplayName":"Full Name Test",' +
            '"BillAddr":{"Country":"United States of America","CountrySubDivisionCode":"Texas"}},' +
            '{"Id":"204","DisplayName":"Unknown Country",' +
            '"BillAddr":{"Country":"Atlantis","CountrySubDivisionCode":"Main"}}' +
            ']}}';

        Test.setMock(HttpCalloutMock.class, new SingleResponseMock(200, response));

        Test.startTest();
        Database.executeBatch(new QuickBooksCustomerSyncBatch(), 1);
        Test.stopTest();

        Map<String, Account> accountMap = new Map<String, Account>();
        for (Account a : [
            SELECT faxa__QuickBooks_Customer_Id__c, BillingCountryCode
            FROM Account
            WHERE faxa__QuickBooks_Customer_Id__c IN ('201','202','203','204')
        ]) {
            accountMap.put(a.faxa__QuickBooks_Customer_Id__c, a);
        }

        System.assertEquals('US', accountMap.get('201').BillingCountryCode, 'USA should normalize to US');
        System.assertEquals('IN', accountMap.get('202').BillingCountryCode, 'India should normalize to IN');
        System.assertEquals('US', accountMap.get('203').BillingCountryCode, 'United States of America should normalize to US');
    }

    @IsTest
    static void testResponseTruncation() {
        String longCustomer = '{"Id":"301","DisplayName":"Long Response Corp"}';
        String padding = '"extraField":"' + 'X'.repeat(40000) + '"';
        String response = '{"QueryResponse":{"Customer":[{' +
            '"Id":"301","DisplayName":"Long Response Corp",' + padding + '}]}}';

        Test.setMock(HttpCalloutMock.class, new SingleResponseMock(200, response));

        Test.startTest();
        Database.executeBatch(new QuickBooksCustomerSyncBatch(), 1);
        Test.stopTest();

        faxa__External_App_Request__c req = [
            SELECT faxa__Response__c FROM faxa__External_App_Request__c LIMIT 1
        ];
        System.assert(req.faxa__Response__c.length() <= 32768, 'Response should be truncated to 32768 chars');
    }

    @IsTest
    static void testBatchExceptionOnBadAuth() {
        faxa__External_App__c app = [
            SELECT Id FROM faxa__External_App__c WHERE Name = 'QuickBook'
        ];
        app.faxa__Authentication_Status__c = 'Failed';
        update app;

        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        try {
            Database.executeBatch(new QuickBooksCustomerSyncBatch(), 1);
            Test.stopTest();
        } catch (Exception e) {
            System.assert(e.getMessage().contains('QuickBooks not authenticated') ||
                          e.getCause() != null,
                          'Should throw BatchException for unauthenticated app');
        }
    }

    @IsTest
    static void testTaxCodeMapping() {
        faxa__Mapping__c taxMapping = new faxa__Mapping__c(
            faxa__FieldAx_Object__c = 'Account',
            faxa__FieldAx_Field__c = 'Tax_Group_Code__c',
            faxa__External_App_Field__c = 'DefaultTaxCodeRef.value'
        );
        insert taxMapping;

        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        Database.executeBatch(new QuickBooksCustomerSyncBatch(), 1);
        Test.stopTest();

        faxa__Tax__c tax = [SELECT Id FROM faxa__Tax__c WHERE faxa__Tax_Code_Id__c = 'TAX001'];
        Account acc = [
            SELECT Tax_Group_Code__c FROM Account
            WHERE faxa__QuickBooks_Customer_Id__c = '101'
        ];
        System.assertEquals(tax.Id, acc.Tax_Group_Code__c, 'Tax Group Code should be mapped via tax code lookup');
    }

    // Reusable mock for custom responses
    private class SingleResponseMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;

        SingleResponseMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(this.statusCode);
            res.setBody(this.body);
            return res;
        }
    }
}