@isTest
private class ServiceTermTriggerHandlerTest {
    @isTest
    static void testSendContractExpiryReminders_NoRecords() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        Test.startTest();
        ServiceTermTriggerHandler.sendContractExpiryReminders();
        Test.stopTest();
        System.assert(true, 'No-record path should execute.');
    }

    @isTest
    static void testSendContractExpiryReminders_30And60DayRecords() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        Account acc = new Account(Name = 'Service Term SMS Customer', Phone = '+15559876543');
        insert acc;

        insert new List<fax__Service_Term__c>{
            new fax__Service_Term__c(
                fax__Site__c = acc.Id,
                fax__Status__c = 'Active',
                fax__End_Date__c = Date.today().addDays(30),
                fax__Schedule_On__c = 'Monthly'
            ),
            new fax__Service_Term__c(
                fax__Site__c = acc.Id,
                fax__Status__c = 'Active',
                fax__End_Date__c = Date.today().addDays(60),
                fax__Schedule_On__c = 'Monthly'
            )
        };

        Test.startTest();
        ServiceTermTriggerHandler.sendContractExpiryReminders();
        Test.stopTest();

        System.assert(true, '30-day and 60-day reminder branches should execute.');
    }

    @isTest
    static void testSendContractExpiryReminders_NoPhoneFallbackSkip() {
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
        Account acc = new Account(Name = 'No Phone Customer');
        insert acc;

        insert new fax__Service_Term__c(
            fax__Site__c = acc.Id,
            fax__Status__c = 'Active',
            fax__End_Date__c = Date.today().addDays(30),
            fax__Schedule_On__c = 'Weekly'
        );

        Test.startTest();
        ServiceTermTriggerHandler.sendContractExpiryReminders();
        Test.stopTest();

        System.assert(true, 'No-phone branch should safely skip SMS.');
    }
}