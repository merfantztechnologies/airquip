@isTest
private class JobInvoiceControllerTest {
    @isTest
    static void deleteInvoiceForJobDeletesRelatedInvoice() {
        Account account = new Account(Name = 'Test Account');
        insert account;

        Contact contact = new Contact(
            LastName = 'Test',
            AccountId = account.Id
        );
        insert contact;

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = account.Id,
            fax__Contact__c = contact.Id,
            fax__Status__c = 'Completed',
            Invoice_Required__c = false
        );
        insert job;

        fax__Invoice__c invoice = new fax__Invoice__c(
            fax__Site__c = account.Id,
            fax__Job__c = job.Id,
            fax__Status__c = 'Draft'
        );
        insert invoice;

        Test.startTest();
        JobInvoiceController.deleteInvoiceForJob(job.Id);
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM fax__Invoice__c WHERE Id = :invoice.Id],
            'The related invoice should be deleted.'
        );
    }

    @isTest
    static void deleteInvoiceForJobNoOpWhenInvoiceMissing() {
        Account account = new Account(Name = 'Test Account');
        insert account;

        Contact contact = new Contact(
            LastName = 'Test',
            AccountId = account.Id
        );
        insert contact;

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = account.Id,
            fax__Contact__c = contact.Id,
            fax__Status__c = 'Completed',
            Invoice_Required__c = false
        );
        insert job;

        Test.startTest();
        JobInvoiceController.deleteInvoiceForJob(job.Id);
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM fax__Invoice__c WHERE fax__Job__c = :job.Id],
            'No invoice should exist for the job.'
        );
    }

    @isTest
    static void deleteInvoiceForJobRequiresJobId() {
        Boolean exceptionThrown = false;

        Test.startTest();
        try {
            JobInvoiceController.deleteInvoiceForJob(null);
        } catch (AuraHandledException ex) {
            exceptionThrown = true;
            System.assertEquals('Job Id is required.', ex.getMessage());
        }
        Test.stopTest();

        System.assertEquals(true, exceptionThrown, 'A null job Id should throw an exception.');
    }
}