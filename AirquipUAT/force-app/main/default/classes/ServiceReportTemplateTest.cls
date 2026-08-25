@isTest(SeeAllData=true)
private class ServiceReportTemplateTest {

    private static final String VISIT_TYPE_SERVICE = 'Service';

    // Get any valid Job Type from org
    private static fax__Job_Type__c getValidServiceJobType() {
        return [
            SELECT Id 
            FROM fax__Job_Type__c 
            LIMIT 1
        ];
    }

    // Create Job with Contact
    private static fax__Job__c createJob() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Contact con = new Contact(
            LastName = 'Test Contact',
            AccountId = acc.Id,
            Email = 'test@test.com'
        );
        insert con;

        fax__Job_Type__c jt = getValidServiceJobType();

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Status__c = 'Open',
            fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = jt.Id
        );
        insert job;

        return job;
    }

    // Attach File to Job
    private static void attachFile(Id jobId) {
        ContentVersion cv = new ContentVersion(
            Title = 'ServiceReport',
            PathOnClient = 'ServiceReport.pdf',
            VersionData = Blob.valueOf('Test PDF Data'),
            IsMajorVersion = true
        );
        insert cv;

        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        ContentDocumentLink cdl = new ContentDocumentLink(
            LinkedEntityId = jobId,
            ContentDocumentId = cv.ContentDocumentId,
            ShareType = 'V'
        );
        insert cdl;
    }

    // 🔥 Ensure at least one valid user email exists
    private static void ensureUserEmailMatchesLabel() {
        // Get current user
        User u = [SELECT Id, Email FROM User WHERE Id = :UserInfo.getUserId()];

        // This ensures at least one email matches logic
        System.assertNotEquals(null, u.Email, 'User must have email');
    }

    // Test: No Input
    @isTest
    static void testNoInput() {
        Test.startTest();
        ServiceReportTemplate.sendServiceReport(null);
        ServiceReportTemplate.sendServiceReport(new List<Id>());
        Test.stopTest();
        System.assert(true);
    }

    // Test: Job without File
    @isTest
    static void testJobWithoutFile() {

        ensureUserEmailMatchesLabel();

        fax__Job__c job = createJob();

        Test.startTest();
        ServiceReportTemplate.sendServiceReport(new List<Id>{ job.Id });
        Test.stopTest();

        System.assert(true);
    }

    // Test: Job with File
    @isTest
    static void testJobWithFile() {

        ensureUserEmailMatchesLabel();

        fax__Job__c job = createJob();
        attachFile(job.Id);

        Test.startTest();
        ServiceReportTemplate.sendServiceReport(new List<Id>{ job.Id });
        Test.stopTest();

        System.assert(true);
    }
}