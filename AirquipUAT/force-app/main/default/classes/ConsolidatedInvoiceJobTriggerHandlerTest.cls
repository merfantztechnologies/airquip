@isTest
private class ConsolidatedInvoiceJobTriggerHandlerTest {
    @TestSetup
    static void setup() {
        Account accountRecord = new Account(Name = 'Consolidated Junction Account');
        Account otherAccount = new Account(Name = 'Other Junction Account');
        insert new List<Account>{ accountRecord, otherAccount };

        Contact siteContact = new Contact(
            LastName = 'Junction Contact',
            AccountId = accountRecord.Id,
            Email = 'junction.contact@example.com',
            Phone = '5552220001'
        );
        Contact otherSiteContact = new Contact(
            LastName = 'Other Junction Contact',
            AccountId = otherAccount.Id,
            Email = 'other.junction.contact@example.com',
            Phone = '5552220002'
        );
        insert new List<Contact>{ siteContact, otherSiteContact };

        List<fax__Job__c> jobs = new List<fax__Job__c>{
            new fax__Job__c(
                fax__Customer__c = accountRecord.Id,
                fax__Contact__c = siteContact.Id,
                fax__Status__c = 'Open',
                fax__Trigger_Job_Sheet_Email__c = false,
                fax__Planned_Visit_Date_Time__c = System.now().addDays(-2),
                fax__Completion_Date_Time__c = System.now().addDays(-2),
                Consolidated_Invoice__c = true,
                Invoice_Required__c = true
            ),
            new fax__Job__c(
                fax__Customer__c = accountRecord.Id,
                fax__Contact__c = siteContact.Id,
                fax__Status__c = 'Open',
                fax__Trigger_Job_Sheet_Email__c = false,
                fax__Planned_Visit_Date_Time__c = System.now().addDays(-1),
                fax__Completion_Date_Time__c = System.now().addDays(-1),
                Consolidated_Invoice__c = true,
                Invoice_Required__c = true
            ),
            new fax__Job__c(
                fax__Customer__c = otherAccount.Id,
                fax__Contact__c = otherSiteContact.Id,
                fax__Status__c = 'Open',
                fax__Trigger_Job_Sheet_Email__c = false,
                fax__Planned_Visit_Date_Time__c = System.now(),
                fax__Completion_Date_Time__c = System.now(),
                Consolidated_Invoice__c = true,
                Invoice_Required__c = true
            )
        };
        insert jobs;

        update new List<fax__Job__c>{
            new fax__Job__c(Id = jobs[0].Id, fax__Status__c = 'Completed'),
            new fax__Job__c(Id = jobs[1].Id, fax__Status__c = 'Completed'),
            new fax__Job__c(Id = jobs[2].Id, fax__Status__c = 'Completed')
        };

        deleteAutoInvoicesForJobs(new List<Id>{ jobs[0].Id, jobs[1].Id, jobs[2].Id });

        Product2 productOne = new Product2(
            Name = 'Junction Product One',
            IsActive = true,
            Family = 'Hardware',
            Description = 'Primary junction product'
        );
        Product2 productTwo = new Product2(
            Name = 'Junction Product Two',
            IsActive = true,
            Family = 'Hardware',
            Description = 'Secondary junction product'
        );
        insert new List<Product2>{ productOne, productTwo };

        insert new List<fax__Job_System__c>{
            new fax__Job_System__c(
                fax__Job_New__c = jobs[0].Id,
                fax__Product__c = productOne.Id,
                fax__Quantity__c = 1,
                fax__Unit_Price__c = 100,
                fax__Discount__c = 0,
                fax__Billable__c = true
            ),
            new fax__Job_System__c(
                fax__Job_New__c = jobs[1].Id,
                fax__Product__c = productTwo.Id,
                fax__Quantity__c = 2,
                fax__Unit_Price__c = 50,
                fax__Discount__c = 0,
                fax__Billable__c = true
            )
        };
    }

    @isTest
    static void afterInsertCreatesInvoiceLineItemsForNonPrimaryJob() {
        Account accountRecord = [SELECT Id FROM Account WHERE Name = 'Consolidated Junction Account' LIMIT 1];
        List<fax__Job__c> jobs = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Customer__c = :accountRecord.Id
            AND fax__Status__c = 'Completed'
            ORDER BY Name ASC
        ];

        fax__Invoice__c invoiceRecord = new fax__Invoice__c(
            fax__Site__c = accountRecord.Id,
            fax__Job__c = jobs[0].Id,
            fax__Status__c = 'Draft'
        );
        insert invoiceRecord;

        Integer lineCountBefore = [
            SELECT COUNT()
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c = :invoiceRecord.Id
        ];

        Test.startTest();
        insert new Consolidated_Invoice_Job__c(
            Invoice__c = invoiceRecord.Id,
            Job__c = jobs[1].Id,
            Account__c = accountRecord.Id
        );
        Test.stopTest();

        Integer lineCountAfter = [
            SELECT COUNT()
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c = :invoiceRecord.Id
        ];
        System.assertEquals(
            lineCountBefore + 1,
            lineCountAfter,
            'One invoice line should be created for the added Job.'
        );
    }

    @isTest
    static void beforeDeleteRemovesInvoiceLineItemsForRemovedJob() {
        Account accountRecord = [SELECT Id FROM Account WHERE Name = 'Consolidated Junction Account' LIMIT 1];
        List<fax__Job__c> jobs = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Customer__c = :accountRecord.Id
            AND fax__Status__c = 'Completed'
            ORDER BY Name ASC
        ];

        fax__Invoice__c invoiceRecord = new fax__Invoice__c(
            fax__Site__c = accountRecord.Id,
            fax__Job__c = jobs[0].Id,
            fax__Status__c = 'Draft'
        );
        insert invoiceRecord;

        Consolidated_Invoice_Job__c junctionRecord = new Consolidated_Invoice_Job__c(
            Invoice__c = invoiceRecord.Id,
            Job__c = jobs[1].Id,
            Account__c = accountRecord.Id
        );
        insert junctionRecord;

        Integer lineCountBeforeDelete = [
            SELECT COUNT()
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c = :invoiceRecord.Id
        ];
        System.assert(lineCountBeforeDelete >= 1, 'Precondition: at least one line item should exist for the added Job.');

        Test.startTest();
        delete junctionRecord;
        Test.stopTest();

        Integer lineCountAfterDelete = [
            SELECT COUNT()
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c = :invoiceRecord.Id
        ];
        System.assertEquals(
            lineCountBeforeDelete - 1,
            lineCountAfterDelete,
            'Deleting the junction record should remove only that Job invoice lines.'
        );
    }

    @isTest
    static void beforeInsertBlocksCustomerMismatch() {
        Account accountRecord = [SELECT Id FROM Account WHERE Name = 'Consolidated Junction Account' LIMIT 1];
        fax__Job__c otherAccountJob = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Customer__c IN (SELECT Id FROM Account WHERE Name = 'Other Junction Account')
            LIMIT 1
        ];

        fax__Invoice__c invoiceRecord = new fax__Invoice__c(
            fax__Site__c = accountRecord.Id,
            fax__Status__c = 'Draft'
        );
        insert invoiceRecord;

        Test.startTest();
        try {
            insert new Consolidated_Invoice_Job__c(
                Invoice__c = invoiceRecord.Id,
                Job__c = otherAccountJob.Id,
                Account__c = accountRecord.Id
            );
            System.assert(false, 'Expected a validation error for mismatched customers.');
        } catch (DmlException ex) {
            System.assert(ex.getMessage().contains('customer'), 'Validation should enforce customer match.');
        }
        Test.stopTest();
    }

    @isTest
    static void afterInsertDeletesIndividualJobInvoiceWhenConsolidated() {
        Account accountRecord = [SELECT Id FROM Account WHERE Name = 'Consolidated Junction Account' LIMIT 1];
        List<fax__Job__c> jobs = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Customer__c = :accountRecord.Id
            AND fax__Status__c = 'Completed'
            ORDER BY Name ASC
        ];

        fax__Invoice__c individualInvoice = new fax__Invoice__c(
            fax__Site__c = accountRecord.Id,
            fax__Job__c = jobs[1].Id,
            fax__Status__c = 'Draft'
        );
        insert individualInvoice;

        fax__Invoice__c consolidatedInvoice = new fax__Invoice__c(
            fax__Site__c = accountRecord.Id,
            fax__Status__c = 'Draft'
        );
        insert consolidatedInvoice;

        Test.startTest();
        insert new Consolidated_Invoice_Job__c(
            Invoice__c = consolidatedInvoice.Id,
            Job__c = jobs[1].Id,
            Account__c = accountRecord.Id
        );
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM fax__Invoice__c WHERE Id = :individualInvoice.Id],
            'The job individual invoice should be deleted after consolidation.'
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM fax__Invoice__c WHERE Id = :consolidatedInvoice.Id],
            'The consolidated invoice should remain.'
        );
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM fax__Invoice_Line_Item__c
                WHERE fax__Invoice__c = :consolidatedInvoice.Id
            ],
            'Line items should be created on the consolidated invoice.'
        );
    }

    @isTest
    static void afterInsertDoesNotDeleteConsolidatedInvoiceWhenJobIsPrimary() {
        Account accountRecord = [SELECT Id FROM Account WHERE Name = 'Consolidated Junction Account' LIMIT 1];
        List<fax__Job__c> jobs = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Customer__c = :accountRecord.Id
            AND fax__Status__c = 'Completed'
            ORDER BY Name ASC
        ];

        fax__Invoice__c consolidatedInvoice = new fax__Invoice__c(
            fax__Site__c = accountRecord.Id,
            fax__Job__c = jobs[0].Id,
            fax__Status__c = 'Draft'
        );
        insert consolidatedInvoice;

        Test.startTest();
        insert new Consolidated_Invoice_Job__c(
            Invoice__c = consolidatedInvoice.Id,
            Job__c = jobs[1].Id,
            Account__c = accountRecord.Id
        );
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM fax__Invoice__c WHERE Id = :consolidatedInvoice.Id],
            'The consolidated invoice should not be deleted when it is also the primary job invoice.'
        );
    }

    @isTest
    static void beforeInsertBlocksDoubleBillingOnNonDraftInvoice() {
        Account accountRecord = [SELECT Id FROM Account WHERE Name = 'Consolidated Junction Account' LIMIT 1];
        fax__Job__c jobRecord = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Customer__c = :accountRecord.Id
            AND fax__Status__c = 'Completed'
            LIMIT 1
        ];

        fax__Invoice__c approvedInvoice = new fax__Invoice__c(
            fax__Site__c = accountRecord.Id,
            fax__Status__c = 'Paid'
        );
        insert approvedInvoice;

        insert new Consolidated_Invoice_Job__c(
            Invoice__c = approvedInvoice.Id,
            Job__c = jobRecord.Id,
            Account__c = accountRecord.Id
        );

        fax__Invoice__c draftInvoice = new fax__Invoice__c(
            fax__Site__c = accountRecord.Id,
            fax__Status__c = 'Draft'
        );
        insert draftInvoice;

        Test.startTest();
        try {
            insert new Consolidated_Invoice_Job__c(
                Invoice__c = draftInvoice.Id,
                Job__c = jobRecord.Id,
                Account__c = accountRecord.Id
            );
            System.assert(false, 'Expected a trigger error for double billing.');
        } catch (DmlException ex) {
            System.assert(
                ex.getMessage().contains('ineligible invoice'),
                'Trigger should block linking a Job that is already on an ineligible invoice.'
            );
        }
        Test.stopTest();
    }

    private static void deleteAutoInvoicesForJobs(List<Id> jobIds) {
        List<fax__Invoice__c> autoCreatedInvoices = [
            SELECT Id
            FROM fax__Invoice__c
            WHERE fax__Job__c IN :jobIds
        ];
        if (!autoCreatedInvoices.isEmpty()) {
            delete autoCreatedInvoices;
        }
    }
}