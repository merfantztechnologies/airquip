@isTest(SeeAllData=true)
private class JobItemTriggerHandlerTest {
    private static final String VISIT_TYPE_SERVICE = 'Service';

    // ─── helpers (mirror JobTriggerHandlerTest) ──────────────────────────

    private static void applyCategoryFromJobType(fax__Job__c job, fax__Job_Type__c jobType) {
        if (jobType == null) return;
        Map<String, Schema.SObjectField> jobFields  = fax__Job__c.SObjectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        if (jobFields.containsKey('fax__Job_Category__c') && typeFields.containsKey('fax__Job_Category__c')) {
            job.put('fax__Job_Category__c', jobType.get('fax__Job_Category__c'));
        }
    }

    private static List<fax__Job_Type__c> getValidServiceJobTypes(Integer howMany) {
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        String soql = 'SELECT Id';
        if (typeFields.containsKey('fax__Job_Category__c')) {
            soql += ', fax__Job_Category__c';
        }
        soql += ' FROM fax__Job_Type__c'
             + ' WHERE Name IN (\'Compressor Service/Repair\', \'Service Call\', \'Service Repair\', \'Oil Sample Collection\', \'General\')'
             + ' LIMIT ' + howMany;
        return (List<fax__Job_Type__c>) Database.query(soql);
    }

    private static Account makeAccount() {
        Account acc = new Account(Name = 'JobItem Trigger Test Account');
        insert acc;
        return acc;
    }

    private static Contact makeContact(Id accountId) {
        Contact siteContact = new Contact(
            LastName = 'JobItem Test Contact',
            Email = 'jobitem.trigger.test@example.com',
            AccountId = accountId
        );
        insert siteContact;
        return siteContact;
    }

    private static fax__Job__c makeJob(Id accountId, fax__Job_Type__c jobType) {
        Contact siteContact = makeContact(accountId);
        fax__Job__c job = new fax__Job__c(
            fax__Customer__c                = accountId,
            fax__Contact__c                 = siteContact.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Status__c                  = 'Open',
            fax__Visit_Type__c              = VISIT_TYPE_SERVICE
        );
        if (jobType != null) {
            job.fax__Job_Type__c = jobType.Id;
            applyCategoryFromJobType(job, jobType);
        }
        insert job;
        return job;
    }

    private static Product2 makeProduct(String name) {
        Product2 p = new Product2(Name = name, IsActive = true);
        insert p;
        return p;
    }

    // ─── tests ───────────────────────────────────────────────────────────

    @isTest
    static void testInsertJobItem_CreatesConditionalChecklists() {
        Account acc = makeAccount();
        List<fax__Job_Type__c> types = getValidServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one valid Service Job Type must exist.');
        fax__Job_Type__c jobType = types[0];

        Product2 prod = makeProduct('Cond Checklist Product');

        fax__Checklist_Item__c conditionalTemplate = new fax__Checklist_Item__c(
            fax__Job_Type__c = jobType.Id,
            Product__c       = prod.Id,
            fax__Is_Conditional__c = true
        );
        insert conditionalTemplate;

        fax__Job__c job = makeJob(acc.Id, jobType);

        Test.startTest();
        fax__Job_System__c jobItem = new fax__Job_System__c(
            fax__Job_New__c  = job.Id,
            fax__Product__c  = prod.Id,
            fax__Quantity__c = 1,
            fax__Unit_Price__c = 0
        );
        insert jobItem;
        Test.stopTest();

        List<fax__Checklist__c> checklists = [
            SELECT Id, fax__Source_Item__c
            FROM   fax__Checklist__c
            WHERE  fax__Job__c = :job.Id
            AND    fax__Source_Item__c = :conditionalTemplate.Id
        ];
        System.assertEquals(1, checklists.size(),
            'Inserting a Job Item should create a conditional checklist when Product + Job Type match.');
    }

    @isTest
    static void testInsertJobItem_NoMatchingProduct_NoChecklist() {
        Account acc = makeAccount();
        List<fax__Job_Type__c> types = getValidServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one valid Service Job Type must exist.');
        fax__Job_Type__c jobType = types[0];

        Product2 templateProd = makeProduct('Template Product');
        Product2 itemProd     = makeProduct('Different Product');

        fax__Checklist_Item__c conditionalTemplate = new fax__Checklist_Item__c(
            fax__Job_Type__c  = jobType.Id,
            Product__c        = templateProd.Id,
            fax__Is_Conditional__c = true
        );
        insert conditionalTemplate;

        fax__Job__c job = makeJob(acc.Id, jobType);

        Test.startTest();
        insert new fax__Job_System__c(
            fax__Job_New__c  = job.Id,
            fax__Product__c  = itemProd.Id,
            fax__Quantity__c = 1,
            fax__Unit_Price__c = 0
        );
        Test.stopTest();

        Integer cnt = [
            SELECT COUNT()
            FROM   fax__Checklist__c
            WHERE  fax__Job__c = :job.Id
            AND    fax__Source_Item__c = :conditionalTemplate.Id
        ];
        System.assertEquals(0, cnt,
            'No conditional checklist should be created when the Product does not match.');
    }

    @isTest
    static void testNonConditionalItem_NotCreatedByJobItemTrigger() {
        Account acc = makeAccount();
        List<fax__Job_Type__c> types = getValidServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one valid Service Job Type must exist.');
        fax__Job_Type__c jobType = types[0];

        Product2 prod = makeProduct('NonCond Product');

        fax__Job__c job = makeJob(acc.Id, jobType);

        fax__Checklist_Item__c nonCondTemplate = new fax__Checklist_Item__c(
            fax__Job_Type__c  = jobType.Id,
            Product__c        = prod.Id,
            fax__Is_Conditional__c = false
        );
        insert nonCondTemplate;

        Test.startTest();
        insert new fax__Job_System__c(
            fax__Job_New__c  = job.Id,
            fax__Product__c  = prod.Id,
            fax__Quantity__c = 1,
            fax__Unit_Price__c = 0
        );
        Test.stopTest();

        Integer cnt = [
            SELECT COUNT()
            FROM   fax__Checklist__c
            WHERE  fax__Job__c = :job.Id
            AND    fax__Source_Item__c = :nonCondTemplate.Id
        ];
        System.assertEquals(0, cnt,
            'Non-conditional checklist items should NOT be created by the Job Item trigger.');
    }

    @isTest
    static void testUpdateJobItem_ProductChanged_ResyncsChecklists() {
        Account acc = makeAccount();
        List<fax__Job_Type__c> types = getValidServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one valid Service Job Type must exist.');
        fax__Job_Type__c jobType = types[0];

        Product2 prodA = makeProduct('Product A');
        Product2 prodB = makeProduct('Product B');

        fax__Checklist_Item__c tmplA = new fax__Checklist_Item__c(
            fax__Job_Type__c  = jobType.Id,
            Product__c        = prodA.Id,
            fax__Is_Conditional__c = true
        );
        fax__Checklist_Item__c tmplB = new fax__Checklist_Item__c(
            fax__Job_Type__c  = jobType.Id,
            Product__c        = prodB.Id,
            fax__Is_Conditional__c = true
        );
        insert new List<fax__Checklist_Item__c>{ tmplA, tmplB };

        fax__Job__c job = makeJob(acc.Id, jobType);

        fax__Job_System__c jobItem = new fax__Job_System__c(
            fax__Job_New__c  = job.Id,
            fax__Product__c  = prodA.Id,
            fax__Quantity__c = 1,
            fax__Unit_Price__c = 0
        );
        insert jobItem;

        Test.startTest();
        jobItem.fax__Product__c = prodB.Id;
        update jobItem;
        Test.stopTest();

        Integer cntA = [
            SELECT COUNT() FROM fax__Checklist__c
            WHERE fax__Job__c = :job.Id AND fax__Source_Item__c = :tmplA.Id
        ];
        Integer cntB = [
            SELECT COUNT() FROM fax__Checklist__c
            WHERE fax__Job__c = :job.Id AND fax__Source_Item__c = :tmplB.Id
        ];
        System.assertEquals(0, cntA, 'Old product checklist should be removed after product change.');
        System.assertEquals(1, cntB, 'New product checklist should be created after product change.');
    }

    @isTest
    static void testDeleteJobItem_RemovesConditionalChecklists() {
        Account acc = makeAccount();
        List<fax__Job_Type__c> types = getValidServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one valid Service Job Type must exist.');
        fax__Job_Type__c jobType = types[0];

        Product2 prod = makeProduct('Delete Test Product');

        fax__Checklist_Item__c tmpl = new fax__Checklist_Item__c(
            fax__Job_Type__c  = jobType.Id,
            Product__c        = prod.Id,
            fax__Is_Conditional__c = true
        );
        insert tmpl;

        fax__Job__c job = makeJob(acc.Id, jobType);

        fax__Job_System__c jobItem = new fax__Job_System__c(
            fax__Job_New__c  = job.Id,
            fax__Product__c  = prod.Id,
            fax__Quantity__c = 1,
            fax__Unit_Price__c = 0
        );
        insert jobItem;

        Integer checklistCountBeforeDelete = [
            SELECT COUNT() FROM fax__Checklist__c
            WHERE fax__Job__c = :job.Id AND fax__Source_Item__c = :tmpl.Id
        ];
        System.assertEquals(1, checklistCountBeforeDelete, 'Precondition: conditional checklist should exist.');

        Test.startTest();
        delete jobItem;
        Test.stopTest();

        Integer checklistCountAfterDelete = [
            SELECT COUNT() FROM fax__Checklist__c
            WHERE fax__Job__c = :job.Id AND fax__Source_Item__c = :tmpl.Id
        ];
        System.assertEquals(0, checklistCountAfterDelete,
            'Conditional checklist should be removed when the Job Item is deleted.');
    }

    @isTest
    static void testHandlerGuard_EmptyInput() {
        Test.startTest();
        JobItemTriggerHandler.syncConditionalChecklists((Set<Id>) null);
        JobItemTriggerHandler.syncConditionalChecklists(new Set<Id>());
        Test.stopTest();

        System.assert(true, 'Guard clauses should handle null/empty input without error.');
    }
}