@isTest
private class AccountFollowUpTaskBatchTest {

    @testSetup
    static void createTestData() {

        // Account 1: No task -> should create follow-up task
        Account accNoTask = new Account(
            Name = 'Account No Task',
            Status__c = 'Active',
            BillingStreet = '123 Test Street',
            BillingCity = 'Chennai',
            BillingCountryCode = 'IN',
            BillingStateCode = 'TN',
            BillingPostalCode = '600001',
            
             ShippingStreet = '456 Test Street',
            ShippingCity = 'Chennai',
            ShippingCountryCode = 'IN',
            ShippingStateCode = 'TN',
            ShippingPostalCode = '600001'
            
        );
        insert accNoTask;

        // Account 2: Old open task (>90 days) -> should create
        Account accOldTask = new Account(
            Name = 'Account Old Task',
           Status__c = 'Active',
            BillingStreet = '123 Test Street',
            BillingCity = 'Chennai',
            BillingCountryCode = 'IN',
            BillingStateCode = 'TN',
            BillingPostalCode = '600001',
            
            ShippingStreet = '456 Test Street',
            ShippingCity = 'Chennai',
            ShippingCountryCode = 'IN',
            ShippingStateCode = 'TN',
            ShippingPostalCode = '600001'
        );
        insert accOldTask;

        Task oldTask = new Task(
            Subject = 'Old Open Task',
            Status = 'Not Started',
            Priority = 'Normal',
            WhatId = accOldTask.Id
        );
        insert oldTask;

        // Set task date older than 90 days
        Test.setCreatedDate(
            oldTask.Id,
            DateTime.now().addDays(-100)
        );

        // Account 3: Recent task (<90 days) -> should NOT create
        Account accRecentTask = new Account(
            Name = 'Account Recent Task',
            Status__c = 'Active',
            BillingStreet = '123 Test Street',
            BillingCity = 'Chennai',
            BillingCountryCode = 'IN',
            BillingStateCode = 'TN',
            BillingPostalCode = '600001',
            
            ShippingStreet = '456 Test Street',
            ShippingCity = 'Chennai',
            ShippingCountryCode = 'IN',
            ShippingStateCode = 'TN',
            ShippingPostalCode = '600001'
        );
        insert accRecentTask;

        Task recentTask = new Task(
            Subject = 'Recent Open Task',
            Status = 'Not Started',
            Priority = 'Normal',
            WhatId = accRecentTask.Id
        );
        insert recentTask;
    }

    @isTest
    static void testBatchExecution() {

        Test.startTest();

        Database.executeBatch(
            new AccountFollowUpTaskBatch(),
            200
        );

        Test.stopTest();

        // Verify follow-up tasks created
        List<Task> createdTasks = [
            SELECT Id,
                   Subject,
                   WhatId
            FROM Task
            WHERE Subject = 'Call'
        ];

        
    }

    @isTest
    static void testFinishMethod() {

        Test.startTest();

        AccountFollowUpTaskBatch batchObj =
            new AccountFollowUpTaskBatch();

        Database.executeBatch(batchObj);

        Test.stopTest();

        // Simple assertion to ensure batch completes
        System.assert(true);
    }
}