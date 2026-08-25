@isTest
private class CaseSlaBreachStampSchedulerTest {

    @testSetup
    static void setupData() {
        Account acc = new Account(
            Name = 'SLA Test Account',
            BillingStreet = '123 Main St',
            BillingCity = 'Houston',
            BillingState = 'Texas',
            BillingPostalCode = '77001',
            BillingCountry = 'United States',
            ShippingStreet = '456 Ship Ave',
            ShippingCity = 'Dallas',
            ShippingState = 'Texas',
            ShippingPostalCode = '75001',
            ShippingCountry = 'United States'
        );
        insert acc;

        Contact con = new Contact(LastName = 'SLA Test Contact', AccountId = acc.Id);
        insert con;

        List<Case> cases = new List<Case>{
            new Case(
                Subject = 'Overdue Case',
                AccountId = acc.Id,
                ContactId = con.Id
            ),
            new Case(
                Subject = 'Future Due Case',
                AccountId = acc.Id,
                ContactId = con.Id
            ),
            new Case(
                Subject = 'Already Breached Case',
                AccountId = acc.Id,
                ContactId = con.Id
            )
        };
        insert cases;

        for (Case caseRecord : cases) {
            if (caseRecord.Subject == 'Overdue Case') {
                caseRecord.SLA_Breached__c = false;
                caseRecord.SLA_Resolution_Due__c = System.now().addHours(-1);
            } else if (caseRecord.Subject == 'Future Due Case') {
                caseRecord.SLA_Breached__c = false;
                caseRecord.SLA_Resolution_Due__c = System.now().addHours(2);
            } else if (caseRecord.Subject == 'Already Breached Case') {
                caseRecord.SLA_Breached__c = true;
                caseRecord.SLA_Resolution_Due__c = System.now().addHours(-2);
            }
        }
        update cases;
    }

    @isTest
    static void testStampSlaBreaches() {
        Test.startTest();
        Integer updatedCount = CaseSlaBreachStampScheduler.stampSlaBreaches();
        Test.stopTest();

        System.assertEquals(1, updatedCount, 'Only the overdue open case should be stamped');

        Case overdueCase = [
            SELECT SLA_Breached__c
            FROM Case
            WHERE Subject = 'Overdue Case'
            LIMIT 1
        ];
        Case futureCase = [
            SELECT SLA_Breached__c
            FROM Case
            WHERE Subject = 'Future Due Case'
            LIMIT 1
        ];
        Case breachedCase = [
            SELECT SLA_Breached__c
            FROM Case
            WHERE Subject = 'Already Breached Case'
            LIMIT 1
        ];

        System.assertEquals(true, overdueCase.SLA_Breached__c, 'Overdue case should be stamped');
        System.assertEquals(false, futureCase.SLA_Breached__c, 'Future due case should not be stamped');
        System.assertEquals(true, breachedCase.SLA_Breached__c, 'Already breached case should remain stamped');
    }

    @isTest
    static void testExecuteSchedulable() {
        Test.startTest();
        new CaseSlaBreachStampScheduler().execute(null);
        Test.stopTest();

        Case overdueCase = [
            SELECT SLA_Breached__c
            FROM Case
            WHERE Subject = 'Overdue Case'
            LIMIT 1
        ];
        System.assertEquals(true, overdueCase.SLA_Breached__c, 'Scheduler execute should stamp overdue cases');
    }

    @isTest
    static void testScheduleHourlyJob() {
        Test.startTest();
        String jobId = CaseSlaBreachStampScheduler.scheduleHourlyJob();
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Hourly schedule job should be created');
    }
}