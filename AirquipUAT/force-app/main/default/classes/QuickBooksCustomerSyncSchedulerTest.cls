@IsTest
private class QuickBooksCustomerSyncSchedulerTest {

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
            new faxa__Mapping__c(faxa__FieldAx_Object__c = 'Account', faxa__FieldAx_Field__c = 'Phone', faxa__External_App_Field__c = 'PrimaryPhone.FreeFormNumber')
        };
        insert mappings;
    }

    private class MockCallout implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"QueryResponse":{"Customer":[' +
                '{"Id":"501","DisplayName":"Scheduled Corp","PrimaryPhone":{"FreeFormNumber":"555-9999"}}' +
                ']}}');
            return res;
        }
    }

    @IsTest
    static void testSchedulerExecutesBatch() {
        Test.setMock(HttpCalloutMock.class, new MockCallout());

        Test.startTest();
        String jobId = System.schedule(
            'Test QB Sync Schedule',
            '0 0 2 * * ?',
            new QuickBooksCustomerSyncScheduler()
        );
        Test.stopTest();

        CronTrigger ct = [
            SELECT Id, CronExpression, State
            FROM CronTrigger
            WHERE Id = :jobId
        ];
        System.assertEquals('0 0 2 * * ?', ct.CronExpression, 'Cron expression should match');
    }

    @IsTest
    static void testSchedulerRunsBatchDirectly() {
        Test.setMock(HttpCalloutMock.class, new MockCallout());

        Test.startTest();
        QuickBooksCustomerSyncScheduler scheduler = new QuickBooksCustomerSyncScheduler();
        scheduler.execute(null);
        Test.stopTest();

        List<Account> accounts = [
            SELECT Name, Phone
            FROM Account
            WHERE faxa__QuickBooks_Customer_Id__c = '501'
        ];
        System.assertEquals(1, accounts.size(), 'Batch should create account via scheduler');
        System.assertEquals('Scheduled Corp', accounts[0].Name);
        System.assertEquals('555-9999', accounts[0].Phone);
    }

    @IsTest
    static void testSchedulerReadsConfigFromMdt() {
        Test.setMock(HttpCalloutMock.class, new MockCallout());

        Test.startTest();
        QuickBooksCustomerSyncScheduler scheduler = new QuickBooksCustomerSyncScheduler();
        scheduler.execute(null);
        Test.stopTest();

        List<Account> accounts = [
            SELECT Id FROM Account
            WHERE faxa__QuickBooks_Customer_Id__c = '501'
        ];
        System.assertEquals(1, accounts.size(), 'Batch should complete using MDT config values');
    }
}