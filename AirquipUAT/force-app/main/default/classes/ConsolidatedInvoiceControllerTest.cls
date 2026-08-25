@isTest
private class ConsolidatedInvoiceControllerTest {
    @isTest
    static void getEligibleJobsReturnsCompletedJobsForAccount() {
        TestData data = createTestData();

        Test.startTest();
        List<ConsolidatedInvoiceController.EligibleJob> rows =
            ConsolidatedInvoiceController.getEligibleJobs(data.account.Id);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Two completed eligible jobs should be returned.');
        for (ConsolidatedInvoiceController.EligibleJob row : rows) {
            System.assert(
                row.status == 'Completed' || row.status == 'Finalized',
                'Only completed jobs are eligible.'
            );
        }
    }

    @isTest
    static void getEligibleJobsExcludesJobsAlreadyOnConsolidatedInvoice() {
        TestData data = createTestData();

        fax__Invoice__c existingInvoice = new fax__Invoice__c(
            fax__Site__c = data.account.Id,
            fax__Status__c = 'Draft'
        );
        insert existingInvoice;

        insert new Consolidated_Invoice_Job__c(
            Invoice__c = existingInvoice.Id,
            Account__c = data.account.Id,
            Job__c = data.eligibleJobs[0].Id,
            Invoice_Job_Key__c = existingInvoice.Id + '-' + data.eligibleJobs[0].Id
        );

        Test.startTest();
        List<ConsolidatedInvoiceController.EligibleJob> rows =
            ConsolidatedInvoiceController.getEligibleJobs(data.account.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'Jobs already on a consolidated invoice should be excluded.');
        System.assertEquals(data.eligibleJobs[1].Id, rows[0].jobId, 'The remaining eligible job should be returned.');
    }

    @isTest
    static void getEligibleJobsExcludesJobsWithoutInvoiceRequired() {
        TestData data = createTestData();

        fax__Job__c invoiceNotRequiredJob = new fax__Job__c(
            fax__Customer__c = data.account.Id,
            fax__Contact__c = [SELECT Id FROM Contact WHERE AccountId = :data.account.Id LIMIT 1].Id,
            fax__Status__c = 'Open',
            fax__Trigger_Job_Sheet_Email__c = false,
            fax__Planned_Visit_Date_Time__c = System.now().addDays(-3),
            fax__Completion_Date_Time__c = System.now().addDays(-3),
            Invoice_Required__c = false
        );
        insert invoiceNotRequiredJob;
        completeJobs(new List<Id>{ invoiceNotRequiredJob.Id }, false);

        Test.startTest();
        List<ConsolidatedInvoiceController.EligibleJob> rows =
            ConsolidatedInvoiceController.getEligibleJobs(data.account.Id);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Jobs without invoice required should be excluded.');
    }

    @isTest
    static void getEligibleJobsIncludesJobsWithDraftInvoice() {
        TestData data = createTestData();

        insert new fax__Invoice__c(
            fax__Site__c = data.account.Id,
            fax__Job__c = data.eligibleJobs[0].Id,
            fax__Status__c = 'Draft'
        );

        Test.startTest();
        List<ConsolidatedInvoiceController.EligibleJob> rows =
            ConsolidatedInvoiceController.getEligibleJobs(data.account.Id);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Jobs with a draft invoice should remain eligible.');
    }

    @isTest
    static void getEligibleJobsExcludesJobsWithPaidInvoice() {
        TestData data = createTestData();

        insert new fax__Invoice__c(
            fax__Site__c = data.account.Id,
            fax__Job__c = data.eligibleJobs[0].Id,
            fax__Status__c = 'Paid'
        );

        Test.startTest();
        List<ConsolidatedInvoiceController.EligibleJob> rows =
            ConsolidatedInvoiceController.getEligibleJobs(data.account.Id);
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'Jobs linked to paid invoices should be excluded.');
        System.assertEquals(data.eligibleJobs[1].Id, rows[0].jobId, 'Only the uninvoiced job should remain eligible.');
    }

    @isTest
    static void generateConsolidatedInvoiceCreatesInvoiceAndJunctionRecords() {
        TestData data = createTestData();

        Test.startTest();
        ConsolidatedInvoiceController.GenerateInvoiceResult result =
            ConsolidatedInvoiceController.generateConsolidatedInvoice(
                data.account.Id,
                new List<Id>{ data.eligibleJobs[0].Id, data.eligibleJobs[1].Id }
            );
        Test.stopTest();

        System.assertEquals(true, result.success, 'The operation should succeed.');
        System.assertEquals(2, result.jobsAddedCount, 'Two jobs should be added.');
        System.assertNotEquals(null, result.invoiceId, 'A consolidated invoice should be created.');

        fax__Invoice__c createdInvoice = [
            SELECT Id, fax__Site__c, fax__Status__c
            FROM fax__Invoice__c
            WHERE Id = :result.invoiceId
        ];
        System.assertEquals(data.account.Id, createdInvoice.fax__Site__c, 'Invoice should belong to the account.');
        System.assertEquals('Draft', createdInvoice.fax__Status__c, 'Invoice should be created in Draft status.');

        System.assertEquals(
            2,
            [SELECT COUNT() FROM Consolidated_Invoice_Job__c WHERE Invoice__c = :result.invoiceId],
            'Two junction records should be created.'
        );

        List<ConsolidatedInvoiceController.EligibleJob> remainingRows =
            ConsolidatedInvoiceController.getEligibleJobs(data.account.Id);
        System.assertEquals(0, remainingRows.size(), 'Added jobs should no longer appear as eligible.');
    }

    @isTest
    static void generateConsolidatedInvoiceRequiresSelection() {
        TestData data = createTestData();

        Test.startTest();
        try {
            ConsolidatedInvoiceController.generateConsolidatedInvoice(data.account.Id, new List<Id>());
            System.assert(false, 'Expected an exception when no jobs are selected.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'An AuraHandledException should be thrown.');
        }
        Test.stopTest();
    }

    @isTest
    static void generateConsolidatedInvoiceRejectsIneligibleJob() {
        TestData data = createTestData();

        Test.startTest();
        try {
            ConsolidatedInvoiceController.generateConsolidatedInvoice(
                data.account.Id,
                new List<Id>{ data.openJob.Id }
            );
            System.assert(false, 'Expected an exception for a non-completed job.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'An AuraHandledException should be thrown.');
        }
        Test.stopTest();
    }

    @isTest
    static void generateConsolidatedInvoiceRejectsJobFromAnotherAccount() {
        TestData data = createTestData();

        Test.startTest();
        try {
            ConsolidatedInvoiceController.generateConsolidatedInvoice(
                data.account.Id,
                new List<Id>{ data.otherAccountJob.Id }
            );
            System.assert(false, 'Expected an exception for a job from another account.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'An AuraHandledException should be thrown.');
        }
        Test.stopTest();
    }

    @isTest
    static void getEligibleJobsRequiresAccountId() {
        Test.startTest();
        try {
            ConsolidatedInvoiceController.getEligibleJobs(null);
            System.assert(false, 'Expected an exception when account Id is null.');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage(), 'An AuraHandledException should be thrown.');
        }
        Test.stopTest();
    }

    private class TestData {
        Account account;
        Account otherAccount;
        List<fax__Job__c> eligibleJobs;
        fax__Job__c openJob;
        fax__Job__c otherAccountJob;
    }

    private static TestData createTestData() {
        TestData data = new TestData();
        data.account = new Account(Name = 'Consolidated Invoice Account');
        data.otherAccount = new Account(Name = 'Other Account');
        insert new List<Account>{ data.account, data.otherAccount };

        Contact siteContact = new Contact(
            LastName = 'Consol Inv Contact',
            AccountId = data.account.Id,
            Email = 'consol.inv.contact@example.com',
            Phone = '5551110001'
        );
        Contact otherSiteContact = new Contact(
            LastName = 'Other Inv Contact',
            AccountId = data.otherAccount.Id,
            Email = 'other.inv.contact@example.com',
            Phone = '5551110002'
        );
        insert new List<Contact>{ siteContact, otherSiteContact };

        data.openJob = new fax__Job__c(
            fax__Customer__c = data.account.Id,
            fax__Contact__c = siteContact.Id,
            fax__Status__c = 'Open',
            fax__Trigger_Job_Sheet_Email__c = false,
            fax__Planned_Visit_Date_Time__c = System.now(),
            Invoice_Required__c = false
        );
        data.otherAccountJob = new fax__Job__c(
            fax__Customer__c = data.otherAccount.Id,
            fax__Contact__c = otherSiteContact.Id,
            fax__Status__c = 'Open',
            fax__Trigger_Job_Sheet_Email__c = false,
            fax__Planned_Visit_Date_Time__c = System.now(),
            Invoice_Required__c = false
        );
        insert new List<fax__Job__c>{ data.openJob, data.otherAccountJob };

        completeJobs(new List<Id>{ data.otherAccountJob.Id });

        List<fax__Job__c> eligibleJobRecords = new List<fax__Job__c>{
            new fax__Job__c(
                fax__Customer__c = data.account.Id,
                fax__Contact__c = siteContact.Id,
                fax__Status__c = 'Open',
                fax__Trigger_Job_Sheet_Email__c = false,
                fax__Planned_Visit_Date_Time__c = System.now().addDays(-2),
                fax__Completion_Date_Time__c = System.now().addDays(-2),
                Invoice_Required__c = true
            ),
            new fax__Job__c(
                fax__Customer__c = data.account.Id,
                fax__Contact__c = siteContact.Id,
                fax__Status__c = 'Open',
                fax__Trigger_Job_Sheet_Email__c = false,
                fax__Planned_Visit_Date_Time__c = System.now().addDays(-1),
                fax__Completion_Date_Time__c = System.now().addDays(-1),
                Invoice_Required__c = true
            )
        };
        insert eligibleJobRecords;

        completeJobs(new List<Id>{ eligibleJobRecords[0].Id, eligibleJobRecords[1].Id }, true);

        data.eligibleJobs = [
            SELECT Id
            FROM fax__Job__c
            WHERE Id IN :eligibleJobRecords
            ORDER BY Name ASC
        ];

        return data;
    }

    private static void completeJobs(List<Id> jobIds) {
        completeJobs(jobIds, true);
    }

    private static void completeJobs(List<Id> jobIds, Boolean invoiceRequired) {
        if (jobIds == null || jobIds.isEmpty()) {
            return;
        }

        completeRequiredChecklists(jobIds);

        List<fax__Job__c> jobsToComplete = new List<fax__Job__c>();
        for (Id jobId : jobIds) {
            jobsToComplete.add(
                new fax__Job__c(
                    Id = jobId,
                    fax__Status__c = 'Completed',
                    Checklist_Completed__c = true,
                    Invoice_Required__c = invoiceRequired,
                    fax__Completion_Date_Time__c = System.now()
                )
            );
        }
        update jobsToComplete;
        deleteAutoInvoicesForJobs(jobIds);
        if (invoiceRequired) {
            restoreInvoiceRequired(jobIds);
        }
    }

    private static void restoreInvoiceRequired(List<Id> jobIds) {
        List<fax__Job__c> jobsToRestore = new List<fax__Job__c>();
        for (Id jobId : jobIds) {
            jobsToRestore.add(new fax__Job__c(Id = jobId, Invoice_Required__c = true));
        }
        update jobsToRestore;
    }

    private static void completeRequiredChecklists(List<Id> jobIds) {
        List<fax__Checklist__c> checklistsToComplete = [
            SELECT Id, fax__Notes__c
            FROM fax__Checklist__c
            WHERE fax__Job__c IN :jobIds
            AND Required__c = true
            AND fax__Notes__c = null
        ];

        if (checklistsToComplete.isEmpty()) {
            return;
        }

        for (fax__Checklist__c checklist : checklistsToComplete) {
            checklist.fax__Notes__c = 'Completed for test';
        }
        update checklistsToComplete;
    }

    private static void deleteAutoInvoicesForJobs(List<Id> jobIds) {
        List<Consolidated_Invoice_Job__c> junctionRecords = [
            SELECT Id
            FROM Consolidated_Invoice_Job__c
            WHERE Job__c IN :jobIds
        ];
        if (!junctionRecords.isEmpty()) {
            delete junctionRecords;
        }

        List<fax__Invoice__c> autoCreatedInvoices = [
            SELECT Id, fax__Job__c
            FROM fax__Invoice__c
            WHERE fax__Job__c IN :jobIds
        ];
        if (autoCreatedInvoices.isEmpty()) {
            return;
        }

        Set<Id> jobsToClear = new Set<Id>();
        for (fax__Invoice__c invoiceRecord : autoCreatedInvoices) {
            jobsToClear.add(invoiceRecord.fax__Job__c);
        }

        List<fax__Job__c> jobsToUpdate = new List<fax__Job__c>();
        for (Id jobId : jobsToClear) {
            jobsToUpdate.add(new fax__Job__c(Id = jobId, Invoice_Required__c = false));
        }
        update jobsToUpdate;
        delete autoCreatedInvoices;
    }
}