@isTest(SeeAllData=true)
private class ChecklistTriggerHandlerTest {
    private static fax__Job__c getExistingJob() {
        fax__Job__c job = [
            SELECT Id, fax__Job_Type__c
            FROM fax__Job__c
            WHERE fax__Job_Type__c != null
            LIMIT 1
        ];

        List<fax__Checklist__c> existingChecklists = [
            SELECT Id
            FROM fax__Checklist__c
            WHERE fax__Job__c = :job.Id
        ];
        if (!existingChecklists.isEmpty()) {
            delete existingChecklists;
        }

        return job;
    }

    private static fax__Checklist_Item__c makeChecklistItem(Id jobTypeId, Boolean required) {
        fax__Checklist_Item__c item = new fax__Checklist_Item__c(
            fax__Job_Type__c = jobTypeId,
            Required__c = required
        );
        insert item;
        return item;
    }

    @isTest
    static void testRequiredChecklistNotesUpdateJobCompletion() {
        fax__Job__c job = getExistingJob();
        fax__Checklist_Item__c requiredItem = makeChecklistItem(job.fax__Job_Type__c, true);

        fax__Checklist__c completedRequired = new fax__Checklist__c(
            fax__Job__c = job.Id,
            fax__Source_Item__c = requiredItem.Id,
            fax__Notes__c = 'Completed'
        );
        fax__Checklist__c incompleteRequired = new fax__Checklist__c(
            fax__Job__c = job.Id,
            fax__Source_Item__c = requiredItem.Id
        );

        insert new List<fax__Checklist__c>{ completedRequired, incompleteRequired };

        job = [
            SELECT Checklist_Completed__c
            FROM fax__Job__c
            WHERE Id = :job.Id
        ];
        System.assertEquals(false, job.Checklist_Completed__c,
            'Job should not be complete while any required checklist has blank notes.');

        incompleteRequired = [
            SELECT Id, fax__Notes__c
            FROM fax__Checklist__c
            WHERE Id = :incompleteRequired.Id
        ];
        incompleteRequired.fax__Notes__c = 'Done';

        Test.startTest();
        update incompleteRequired;
        Test.stopTest();

        job = [
            SELECT Checklist_Completed__c
            FROM fax__Job__c
            WHERE Id = :job.Id
        ];
        System.assertEquals(true, job.Checklist_Completed__c,
            'Job should be complete when every required checklist has notes.');
    }

    @isTest
    static void testRequiredFlagChangeRecalculatesJobCompletion() {
        fax__Job__c job = getExistingJob();
        fax__Checklist_Item__c requiredItem = makeChecklistItem(job.fax__Job_Type__c, true);
        fax__Checklist_Item__c optionalItem = makeChecklistItem(job.fax__Job_Type__c, false);

        fax__Checklist__c incompleteRequired = new fax__Checklist__c(
            fax__Job__c = job.Id,
            fax__Source_Item__c = requiredItem.Id
        );
        fax__Checklist__c completedRequired = new fax__Checklist__c(
            fax__Job__c = job.Id,
            fax__Source_Item__c = requiredItem.Id,
            fax__Notes__c = 'Done'
        );
        insert new List<fax__Checklist__c>{ incompleteRequired, completedRequired };

        incompleteRequired = [
            SELECT Id, fax__Source_Item__c
            FROM fax__Checklist__c
            WHERE Id = :incompleteRequired.Id
        ];
        incompleteRequired.fax__Source_Item__c = optionalItem.Id;

        Test.startTest();
        update incompleteRequired;
        Test.stopTest();

        job = [
            SELECT Checklist_Completed__c
            FROM fax__Job__c
            WHERE Id = :job.Id
        ];
        System.assertEquals(true, job.Checklist_Completed__c,
            'Job should be complete after the only blank checklist is no longer required.');
    }

    @isTest
    static void testOptionalChecklistDoesNotMakeJobIncomplete() {
        fax__Job__c job = getExistingJob();
        fax__Checklist_Item__c optionalItem = makeChecklistItem(job.fax__Job_Type__c, false);

        Test.startTest();
        insert new fax__Checklist__c(
            fax__Job__c = job.Id,
            fax__Source_Item__c = optionalItem.Id
        );
        Test.stopTest();

        job = [
            SELECT Checklist_Completed__c
            FROM fax__Job__c
            WHERE Id = :job.Id
        ];
        System.assertEquals(true, job.Checklist_Completed__c,
            'Optional checklists should leave the Job complete even when notes are blank.');
    }
}