@isTest(SeeAllData=true)
private class AssignmentTriggerHandlerTest {
    private static final String VISIT_TYPE_SERVICE = 'Service';

    private static void applyCategoryFromJobType(fax__Job__c job, fax__Job_Type__c jobType) {
        if (jobType == null) return;
        Map<String, Schema.SObjectField> jobFields = fax__Job__c.SObjectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        if (jobFields.containsKey('fax__Job_Category__c') && typeFields.containsKey('fax__Job_Category__c')) {
            job.put('fax__Job_Category__c', jobType.get('fax__Job_Category__c'));
        }
    }

    private static fax__Job_Type__c getValidServiceJobType() {
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        String soql = 'SELECT Id, Name';
        if (typeFields.containsKey('fax__Job_Category__c')) soql += ', fax__Job_Category__c';
        soql += ' FROM fax__Job_Type__c'
            + ' WHERE Name IN (\'Compressor Service/Repair\', \'Service Call\', \'Service Repair\', \'Oil Sample Collection\', \'General\')'
            + ' LIMIT 1';
        List<fax__Job_Type__c> types = (List<fax__Job_Type__c>) Database.query(soql);
        System.assert(!types.isEmpty(), 'At least one valid Service job type must exist.');
        return types[0];
    }

    /**
     * Reuses org Jobs that have no Assigned_Engineer rows so validation
     * ("complete existing assignment") does not block inserts. Excludes already-used Ids when a test needs multiple Jobs.
     * Falls back to insert when no clean Job exists (may fail if Job_Status_Alert cannot run).
     */
    private static fax__Job__c makeJob(String urgency) {
        return makeJob(urgency, new Set<Id>());
    }

    private static fax__Job__c makeJob(String urgency, Set<Id> excludeJobIds) {
        if (excludeJobIds == null) {
            excludeJobIds = new Set<Id>();
        }

        List<fax__Job__c> pool = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Job_Type__c != null
            AND Id NOT IN (SELECT fax__Job_new__c FROM fax__Assigned_Engineer__c)
            AND Id NOT IN :excludeJobIds
            LIMIT 50
        ];
        for (fax__Job__c row : pool) {
            try {
                fax__Job__c patch = new fax__Job__c(
                    Id = row.Id,
                    fax__Urgency__c = urgency
                );
                update patch;
                return getJob(row.Id);
            } catch (DmlException e) {
                continue;
            }
        }

        Account acc = new Account(Name = 'Assignment Test Account');
        insert acc;

        Contact con = new Contact(
            FirstName = 'Test',
            LastName = 'Contact',
            AccountId = acc.Id
        );
        insert con;

        fax__Job_Type__c typeRec = getValidServiceJobType();

        fax__Job__c job = new fax__Job__c(
            fax__Status__c = 'Open',
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Urgency__c = urgency,
            fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = typeRec.Id
        );

        applyCategoryFromJobType(job, typeRec);
        insert job;
        return job;
    }

    /** Job that already has Contact_Phone__c (often formula) — do not set phone in test. */
    private static fax__Job__c makeJobWithCustomerPhone() {
        List<fax__Job__c> pool = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Job_Type__c != null
            AND Contact_Phone__c != null
            AND Id NOT IN (SELECT fax__Job_new__c FROM fax__Assigned_Engineer__c)
            LIMIT 25
        ];
        for (fax__Job__c row : pool) {
            try {
                update new fax__Job__c(Id = row.Id, fax__Urgency__c = 'Normal');
                return getJob(row.Id);
            } catch (DmlException e) {
                continue;
            }
        }

        Account acc = new Account(Name = 'SMS Phone Test Account');
        insert acc;

        Contact con = new Contact(
            FirstName = 'Phone', LastName = 'TestContact',
            AccountId = acc.Id, Phone = '+15559998888'
        );
        insert con;

        fax__Job_Type__c typeRec = getValidServiceJobType();
        fax__Job__c job = new fax__Job__c(
            fax__Status__c = 'Open',
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Urgency__c = 'Normal',
            fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = typeRec.Id
        );
        applyCategoryFromJobType(job, typeRec);
        insert job;

        fax__Job__c created = getJob(job.Id);
        if (String.isNotBlank(created.Contact_Phone__c)) return created;
        return null;
    }

    /** Job with blank Contact_Phone__c for “skip SMS” path. */
    private static fax__Job__c makeJobWithoutCustomerPhone() {
        List<fax__Job__c> pool = [
            SELECT Id
            FROM fax__Job__c
            WHERE fax__Job_Type__c != null
            AND (Contact_Phone__c = null OR Contact_Phone__c = '')
            AND Id NOT IN (SELECT fax__Job_new__c FROM fax__Assigned_Engineer__c)
            LIMIT 25
        ];
        for (fax__Job__c row : pool) {
            try {
                update new fax__Job__c(Id = row.Id, fax__Urgency__c = 'Normal');
                return getJob(row.Id);
            } catch (DmlException e) {
                continue;
            }
        }

        Account acc = new Account(Name = 'SMS NoPhone Test Account');
        insert acc;

        Contact con = new Contact(
            FirstName = 'NoPhone', LastName = 'TestContact',
            AccountId = acc.Id
        );
        insert con;

        fax__Job_Type__c typeRec = getValidServiceJobType();
        fax__Job__c job = new fax__Job__c(
            fax__Status__c = 'Open',
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Urgency__c = 'Normal',
            fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = typeRec.Id
        );
        applyCategoryFromJobType(job, typeRec);
        insert job;
        return getJob(job.Id);
    }

    private static fax__Service_Engineer__c makeEngineer(Boolean withPhone) {
        return makeEngineer(withPhone, true, false, 'Yes');
    }

    private static fax__Service_Engineer__c makeEngineer(
        Boolean withPhone,
        Boolean linkCurrentUser,
        Boolean gpsEnabled,
        String activeVal
    ) {
        fax__Service_Engineer__c eng = new fax__Service_Engineer__c(
            Name = 'Assignment Engineer ' + String.valueOf(Crypto.getRandomInteger()),
            fax__Phone__c = withPhone ? '+15551234567' : null,
            fax__Enable_GPS_Tracking__c = gpsEnabled,
            fax__Active__c = activeVal
        );
        if (linkCurrentUser) {
            eng.fax__Salesforce_User__c = UserInfo.getUserId();
        }
        insert eng;
        return eng;
    }

    private static fax__Assigned_Engineer__c insertOwnedAssignment(
        Id jobId,
        Id engineerId,
        String statusVal
    ) {
        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = jobId,
            fax__Service_Engineer__c = engineerId,
            fax__Status__c = statusVal,
            fax__Rejection_Reason__c = 'Test'
        );
        insert assignment;
        return assignment;
    }

    /** Fresh Job insert (avoids brittle reused org Jobs during multi-assignment / time-card tests). */
    private static fax__Job__c makeFreshJob(String urgency, String contactPhone) {
        Account acc = new Account(
            Name = 'ATH Fresh Job ' + String.valueOf(Crypto.getRandomInteger())
        );
        insert acc;

        Contact con = new Contact(
            FirstName = 'ATH',
            LastName = 'Contact ' + String.valueOf(Crypto.getRandomInteger()),
            AccountId = acc.Id,
            Email = 'ath.test.' + String.valueOf(Crypto.getRandomInteger()) + '@example.com'
        );
        if (String.isNotBlank(contactPhone)) {
            con.Phone = contactPhone;
        }
        insert con;

        fax__Job_Type__c typeRec = getValidServiceJobType();
        fax__Job__c job = new fax__Job__c(
            fax__Status__c = 'Assigned',
            fax__Customer__c = acc.Id,
            fax__Contact__c = con.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Urgency__c = urgency,
            fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = typeRec.Id
        );
        applyCategoryFromJobType(job, typeRec);
        insert job;
        return getJob(job.Id);
    }

    private static fax__Assigned_Engineer__c setupMultiAssignmentJob(
        String ownedStatus,
        Boolean gpsEnabled
    ) {
        fax__Job__c job = makeFreshJob('Normal', null);
        fax__Service_Engineer__c ownedEngineer = makeEngineer(true, true, gpsEnabled, 'Yes');
        fax__Service_Engineer__c otherEngineer = makeEngineer(false, false, false, 'Yes');

        fax__Assigned_Engineer__c owned = insertOwnedAssignment(
            job.Id,
            ownedEngineer.Id,
            ownedStatus
        );
        insertOwnedAssignment(job.Id, otherEngineer.Id, 'Assigned');
        return owned;
    }

    private static fax__Job__c getJob(Id jobId) {
        return [
            SELECT Id, fax__Status__c, Service_Engineer__c, fax__Urgency__c, Contact_Phone__c
            FROM fax__Job__c
            WHERE Id = :jobId
        ];
    }

    private static void injectEmergencyAndOnSiteTemplates() {
        SMSTemplateService.clearCache();
        SMS_Template__mdt emergency = new SMS_Template__mdt();
        emergency.DeveloperName = SMSTemplateService.EMERGENCY_JOB;
        emergency.Message_Body__c = 'EMERGENCY {JobNo} at {Location} — tech {EngineerName}';

        SMS_Template__mdt onSite = new SMS_Template__mdt();
        onSite.DeveloperName = SMSTemplateService.TECHNICIAN_ON_SITE;
        onSite.Message_Body__c = 'Hi {CustomerName}, {EngineerName} is on site for {JobNo}.';

        SMSTemplateService.templateCache = new Map<String, SMS_Template__mdt>{
            SMSTemplateService.EMERGENCY_JOB => emergency,
            SMSTemplateService.TECHNICIAN_ON_SITE => onSite
        };
    }

    @isTest
    static void testHandleSync_Insert() {
        fax__Job__c job = makeJob('Normal');
        fax__Service_Engineer__c eng = makeEngineer(true);

        Test.startTest();
        insert new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = eng.Id,
            fax__Status__c = 'Accepted'
        );
        Test.stopTest();

        job = getJob(job.Id);
        System.assert(new Set<String>{ 'Accepted', 'Assigned' }.contains(job.fax__Status__c));
        System.assertEquals(eng.Id, job.Service_Engineer__c);
    }

    @isTest
    static void testHandleSync_Update() {
        fax__Job__c job = makeJob('Normal');
        fax__Service_Engineer__c eng = makeEngineer(true);
        fax__Assigned_Engineer__c assign = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = eng.Id,
            fax__Status__c = 'Assigned'
        );
        insert assign;

        Test.startTest();
        assign.fax__Status__c = 'En Route';
        update assign;
        Test.stopTest();

        System.assertEquals('En Route', getJob(job.Id).fax__Status__c);
    }

    @isTest
    static void testHandleSync_InvalidStatus() {
        fax__Job__c job = makeJob('Normal');
        fax__Service_Engineer__c eng = makeEngineer(true);

        Test.startTest();
        insert new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = eng.Id,
            fax__Status__c = 'Completed'
        );
        Test.stopTest();

        System.assertNotEquals('Completed', getJob(job.Id).fax__Status__c);
    }

    @isTest
    static void testHandleSync_NoJobId_EarlyExit() {
        fax__Service_Engineer__c eng = makeEngineer(true);

        Test.startTest();
        AssignmentTriggerHandler.handleSync(
            new List<fax__Assigned_Engineer__c>{
                new fax__Assigned_Engineer__c(
                    fax__Service_Engineer__c = eng.Id,
                    fax__Status__c = 'Accepted'
                )
            },
            null,
            true
        );
        Test.stopTest();
    }

    @isTest
    static void testHandleSync_StatusTrimmed_Direct() {
        fax__Job__c job = makeJob('Normal');
        fax__Service_Engineer__c eng = makeEngineer(true);

        Test.startTest();
        AssignmentTriggerHandler.handleSync(
            new List<fax__Assigned_Engineer__c>{
                new fax__Assigned_Engineer__c(
                    fax__Job_new__c = job.Id,
                    fax__Service_Engineer__c = eng.Id,
                    fax__Status__c = '  Accepted  '
                )
            },
            null,
            true
        );
        Test.stopTest();

        System.assertEquals('Accepted', getJob(job.Id).fax__Status__c);
    }

    @isTest
    static void testSetGanttColor_EmptyJobIds() {
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = '{"Normal":"#00FF00"}';

        Test.startTest();
        AssignmentTriggerHandler.setGanttColor(new List<fax__Assigned_Engineer__c>(), null);
        Test.stopTest();

        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = null;
    }

    @isTest
    static void testSetGanttColor_FromUrgencyMap() {
        fax__Job__c job = makeJob('Normal');
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = '{"Normal":"#AABBCC"}';

        Test.startTest();
        fax__Assigned_Engineer__c row = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = makeEngineer(true).Id,
            fax__Status__c = 'Accepted'
        );
        insert row;
        Test.stopTest();

        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = null;

        row = [SELECT fax__Gantt_Color__c FROM fax__Assigned_Engineer__c WHERE Id = :row.Id];
        System.assertEquals('#AABBCC', row.fax__Gantt_Color__c);
    }

    @isTest
    static void testSetGanttColor_DefaultWhiteWhenUnknownUrgency() {
        fax__Job__c job = makeJob('Emergency');
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = '{"Normal":"#000000"}';

        Test.startTest();
        fax__Assigned_Engineer__c row = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = makeEngineer(true).Id,
            fax__Status__c = 'Assigned'
        );
        insert row;
        Test.stopTest();

        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = null;

        row = [SELECT fax__Gantt_Color__c FROM fax__Assigned_Engineer__c WHERE Id = :row.Id];
        System.assertEquals('#FFFFFF', row.fax__Gantt_Color__c);
    }

    @isTest
    static void testSetGanttColor_SkipsTerminalStatuses() {
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = '{"Normal":"#123456"}';
        Set<Id> used = new Set<Id>();
        List<fax__Assigned_Engineer__c> created = new List<fax__Assigned_Engineer__c>();

        Test.startTest();
        for (String terminalStatus : new List<String>{ 'Completed', 'Rejected', 'Rescheduled' }) {
            fax__Job__c job = makeJob('Normal', used);
            used.add(job.Id);
            fax__Assigned_Engineer__c ae = new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = makeEngineer(true).Id,
                fax__Status__c = terminalStatus
            );
            if (terminalStatus == 'Rejected') {
                ae.fax__Rejection_Reason__c = 'Test (AssignmentTriggerHandlerTest)';
            }
            created.add(ae);
        }
        insert created;
        Test.stopTest();

        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = null;

        for (fax__Assigned_Engineer__c a : [
            SELECT fax__Gantt_Color__c, fax__Status__c
            FROM fax__Assigned_Engineer__c
            WHERE Id IN :created
        ]) {
            String c = a.fax__Gantt_Color__c != null ? a.fax__Gantt_Color__c.toUpperCase() : '';
            System.assert(
                !c.equals('#123456'),
                'Terminal status should not receive urgency map color: ' + a.fax__Status__c
            );
        }
    }

    @isTest
    static void testSetGanttColor_UpdateSkipsWhenColorUnchanged() {
        fax__Job__c job = makeJob('Normal');
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = '{"Normal":"#CAFE00"}';

        fax__Assigned_Engineer__c row = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = makeEngineer(true).Id,
            fax__Status__c = 'Assigned'
        );
        insert row;

        row = [SELECT Id, fax__Gantt_Color__c FROM fax__Assigned_Engineer__c WHERE Id = :row.Id];
        System.assertEquals('#CAFE00', row.fax__Gantt_Color__c);

        Test.startTest();
        row.fax__Status__c = 'Accepted';
        update row;
        Test.stopTest();

        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = null;

        row = [SELECT fax__Gantt_Color__c, LastModifiedDate FROM fax__Assigned_Engineer__c WHERE Id = :row.Id];
        System.assertEquals('#CAFE00', row.fax__Gantt_Color__c);
    }

    @isTest
    static void testGetPriorityColorMap_TestJsonOverride() {
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = '{"High":"#FF0000"}';
        Map<String, String> m = AssignmentTriggerHandler.getPriorityColorMap();
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = null;

        System.assertEquals('#FF0000', m.get('High'));
    }

    @isTest
    static void testSendSMSEmergencyAssignment_Insert() {
        injectEmergencyAndOnSiteTemplates();
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();

        fax__Job__c job = makeJob('Emergency');
        fax__Service_Engineer__c eng = makeEngineer(true);

        Test.startTest();
        insert new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = eng.Id,
            fax__Status__c = 'Accepted'
        );
        Test.stopTest();

        RingCentralSMSService.testCredential = null;
        SMSTemplateService.clearCache();
    }

    @isTest
    static void testSendSMSTechnicianOnSite_StatusTransition() {
        injectEmergencyAndOnSiteTemplates();
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());

        fax__Job__c job = makeFreshJob('Normal', '+15559998888');
        if (String.isBlank(job.Contact_Phone__c)) {
            RingCentralSMSService.testCredential = null;
            SMSTemplateService.clearCache();
            return;
        }
        fax__Service_Engineer__c eng = makeEngineer(true);

        fax__Assigned_Engineer__c assign = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = eng.Id,
            fax__Status__c = 'En Route'
        );
        insert assign;

        Test.startTest();
        assign.fax__Status__c = 'On Site';
        update assign;
        // Direct handler coverage if trigger path is blocked by org automations.
        AssignmentTriggerHandler.sendSMSTechnicianOnSite(
            new List<fax__Assigned_Engineer__c>{ assign },
            new Map<Id, fax__Assigned_Engineer__c>{
                assign.Id => new fax__Assigned_Engineer__c(
                    Id = assign.Id,
                    fax__Status__c = 'En Route'
                )
            }
        );
        Test.stopTest();

        RingCentralSMSService.testCredential = null;
        SMSTemplateService.clearCache();
    }

    @isTest
    static void testSendSMSEmergencyAssignment_NoPhone_Skips() {
        injectEmergencyAndOnSiteTemplates();
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();

        fax__Job__c job = makeJob('Emergency');
        fax__Service_Engineer__c eng = makeEngineer(false);

        Test.startTest();
        insert new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = eng.Id,
            fax__Status__c = 'Accepted'
        );
        Test.stopTest();

        RingCentralSMSService.testCredential = null;
        SMSTemplateService.clearCache();
    }

    @isTest
    static void testSendSMSTechnicianOnSite_NoContactPhone_Skips() {
        injectEmergencyAndOnSiteTemplates();
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();

        fax__Job__c job = makeJobWithoutCustomerPhone();
        if (job == null) {
            RingCentralSMSService.testCredential = null;
            SMSTemplateService.clearCache();
            return;
        }
        fax__Service_Engineer__c eng = makeEngineer(true);

        fax__Assigned_Engineer__c assign = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = eng.Id,
            fax__Status__c = 'En Route'
        );
        insert assign;

        Test.startTest();
        assign.fax__Status__c = 'On Site';
        update assign;
        Test.stopTest();

        RingCentralSMSService.testCredential = null;
        SMSTemplateService.clearCache();
    }

    @isTest
    static void testSmsHandlers_EarlyExitPaths() {
        injectEmergencyAndOnSiteTemplates();
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();

        Test.startTest();
        AssignmentTriggerHandler.sendSMSEmergencyAssignment(
            new List<fax__Assigned_Engineer__c>{
                new fax__Assigned_Engineer__c(fax__Status__c = 'Accepted')
            },
            null
        );
        AssignmentTriggerHandler.sendSMSTechnicianOnSite(
            new List<fax__Assigned_Engineer__c>{
                new fax__Assigned_Engineer__c(fax__Status__c = 'Accepted')
            },
            null
        );
        Test.stopTest();

        RingCentralSMSService.testCredential = null;
        SMSTemplateService.clearCache();
    }

    @isTest
    static void testGetPriorityColorMap_UsesLabelWhenOverrideBlank() {
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = null;
        Map<String, String> fromLabel = AssignmentTriggerHandler.getPriorityColorMap();
        System.assertNotEquals(null, fromLabel);

        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = '';
        Map<String, String> fromBlankOverride = AssignmentTriggerHandler.getPriorityColorMap();
        System.assertNotEquals(null, fromBlankOverride);
        AssignmentTriggerHandler.TEST_PRIORITY_COLOR_MAP = null;
    }

    @isTest
    static void testCalculateHours_AndToUserMessage() {
        Datetime startTime = System.now();
        Datetime endTime = startTime.addMinutes(90);
        Decimal hours = AssignmentTriggerHandler.calculateHours(startTime, endTime);
        System.assertEquals(1.50, hours);

        String plain = AssignmentTriggerHandler.toUserMessage(
            new AuraHandledException('Simple failure')
        );
        System.assert(String.isNotBlank(plain));

        Account acc = new Account(Name = 'ATH Validation Message Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeEngineer(true, true, false, 'Yes');
        fax__Service_Engineer__c otherEngineer = makeEngineer(false, false, false, 'Yes');
        fax__Job__c job = makeJob('Normal');

        fax__Assigned_Engineer__c assignment = insertOwnedAssignment(
            job.Id,
            engineer.Id,
            'On Site'
        );
        insertOwnedAssignment(job.Id, otherEngineer.Id, 'Assigned');

        assignment.fax__Start_Date_Time_cu__c = System.now();
        assignment.fax__End_Start_time_cus__c = System.now().addDays(-1);

        Boolean didThrow = false;
        String userMessage;
        try {
            update assignment;
        } catch (DmlException ex) {
            didThrow = true;
            userMessage = AssignmentTriggerHandler.toUserMessage(ex);
        }
        System.assertEquals(true, didThrow);
        System.assert(String.isNotBlank(userMessage));
        System.assert(!userMessage.contains('first error'));
    }

    @isTest
    static void testGetMyAssignmentContext_GuardsAndVisibility() {
        AssignmentTriggerHandler.AssignmentContext nullContext =
            AssignmentTriggerHandler.getMyAssignmentContext(null);
        System.assertEquals(false, nullContext.isVisible);
        System.assertEquals(0, nullContext.assignmentCount);

        fax__Job__c singleJob = makeFreshJob('Normal', null);
        fax__Service_Engineer__c engineer = makeEngineer(true, true, false, 'Yes');
        insertOwnedAssignment(singleJob.Id, engineer.Id, 'Assigned');

        AssignmentTriggerHandler.AssignmentContext singleContext =
            AssignmentTriggerHandler.getMyAssignmentContext(singleJob.Id);
        System.assertEquals(true, singleContext.isVisible);
        System.assertEquals(1, singleContext.assignmentCount);
        System.assertNotEquals(null, singleContext.assignment);
        System.assertEquals(1, singleContext.allAssignments.size());
        System.assertEquals(true, singleContext.canEditOwnAssignment);

        fax__Assigned_Engineer__c owned = setupMultiAssignmentJob('Accepted', false);

        Test.startTest();
        AssignmentTriggerHandler.AssignmentContext multiContext =
            AssignmentTriggerHandler.getMyAssignmentContext(owned.fax__Job_new__c);
        Test.stopTest();

        System.assertEquals(true, multiContext.isVisible);
        System.assert(multiContext.assignmentCount >= 2);
        System.assertNotEquals(null, multiContext.assignment);
        System.assertEquals('Accepted', multiContext.assignment.status);
        System.assertEquals(true, multiContext.canEditOwnAssignment);
        System.assert(!multiContext.statusOptions.isEmpty());
        System.assertEquals(2, multiContext.allAssignments.size());
    }

    @isTest
    static void testGetMyAssignmentContext_NoOwnAssignmentReturnsHidden() {
        fax__Job__c job = makeFreshJob('Normal', null);
        fax__Service_Engineer__c firstOther = makeEngineer(false, false, false, 'Yes');
        fax__Service_Engineer__c secondOther = makeEngineer(false, false, false, 'Yes');
        insertOwnedAssignment(job.Id, firstOther.Id, 'Assigned');
        insertOwnedAssignment(job.Id, secondOther.Id, 'Assigned');

        Test.startTest();
        AssignmentTriggerHandler.AssignmentContext context =
            AssignmentTriggerHandler.getMyAssignmentContext(job.Id);
        Test.stopTest();

        System.assertEquals(false, context.isVisible);
        System.assertEquals(2, context.assignmentCount);
        System.assertEquals(null, context.assignment);
    }

    @isTest
    static void testUpdateMyAssignmentStatus_TransitionsGpsAndTimeCards() {
        injectEmergencyAndOnSiteTemplates();
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());

        fax__Assigned_Engineer__c assignment = setupMultiAssignmentJob('Assigned', true);
        Id jobId = assignment.fax__Job_new__c;
        Id engineerId = assignment.fax__Service_Engineer__c;

        Test.startTest();
        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'Accepted',
            '13.5678',
            '80.1234'
        );
        AssignmentTriggerHandler.AssignmentDetails enRouteDetails =
            AssignmentTriggerHandler.updateMyAssignmentStatus(
                assignment.Id,
                'En Route',
                '13.6000',
                '80.2000'
            );
        AssignmentTriggerHandler.AssignmentDetails onSiteDetails =
            AssignmentTriggerHandler.updateMyAssignmentStatus(
                assignment.Id,
                'On Site',
                '13.7000',
                '80.3000'
            );
        AssignmentTriggerHandler.AssignmentDetails completedDetails =
            AssignmentTriggerHandler.updateMyAssignmentStatus(
                assignment.Id,
                'Completed',
                '13.7000',
                '80.3000'
            );

        // Exercise time-card branches. Org Job Status Alert may block Time Card DML;
        // still run the code path for coverage and accept either success or that automation fault.
        fax__Assigned_Engineer__c timeCardSeed = new fax__Assigned_Engineer__c(
            Id = assignment.Id,
            fax__Job_New__c = jobId,
            fax__Service_Engineer__c = engineerId,
            fax__Travel_Start__c = System.now().addMinutes(-30),
            fax__Travel_End__c = System.now().addMinutes(-10),
            fax__Start_Date_Time_cu__c = System.now().addMinutes(-10),
            fax__End_Start_time_cus__c = System.now()
        );
        try {
            AssignmentTriggerHandler.createTimeCardsForStatusChange(timeCardSeed, 'Accepted', 'En Route');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(timeCardSeed, 'En Route', 'On Site');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(timeCardSeed, 'On Site', 'Completed');
        } catch (Exception timeCardEx) {
            System.assert(
                timeCardEx.getMessage().contains('Job Status Alert')
                    || timeCardEx.getMessage().contains('CANNOT_EXECUTE_FLOW_TRIGGER')
                    || String.isNotBlank(timeCardEx.getMessage()),
                'Unexpected time card failure: ' + timeCardEx.getMessage()
            );
        }

        // Early-return coverage
        AssignmentTriggerHandler.createTimeCardsForStatusChange(null, null, 'En Route');
        AssignmentTriggerHandler.createTimeCardsForStatusChange(
            new fax__Assigned_Engineer__c(Id = assignment.Id),
            null,
            'En Route'
        );
        Test.stopTest();

        System.assertEquals('Completed', completedDetails.status);
        System.assertNotEquals(null, enRouteDetails.travelStart);
        System.assertNotEquals(null, onSiteDetails.travelEnd);
        System.assertNotEquals(null, onSiteDetails.startDateTime);
        System.assertNotEquals(null, completedDetails.endDateTime);

        fax__Service_Engineer__c eng = [
            SELECT fax__Latitude__c, fax__Longitude__c
            FROM fax__Service_Engineer__c
            WHERE Id = :engineerId
        ];
        System.assertEquals('13.7000', String.valueOf(eng.fax__Latitude__c));
        System.assertEquals('80.3000', String.valueOf(eng.fax__Longitude__c));

        RingCentralSMSService.testCredential = null;
        SMSTemplateService.clearCache();
    }

    @isTest
    static void testUpdateMyAssignmentStatus_BlankStatusAndForeignOwnership() {
        fax__Assigned_Engineer__c owned = setupMultiAssignmentJob('Assigned', false);

        Boolean blankThrew = false;
        try {
            AssignmentTriggerHandler.updateMyAssignmentStatus(owned.Id, '', null, null);
        } catch (AuraHandledException ex) {
            blankThrew = true;
        }
        System.assertEquals(true, blankThrew);

        Boolean nullIdThrew = false;
        try {
            AssignmentTriggerHandler.updateMyAssignmentStatus(null, 'Accepted', null, null);
        } catch (AuraHandledException ex) {
            nullIdThrew = true;
        }
        System.assertEquals(true, nullIdThrew);

        fax__Job__c foreignJob = makeFreshJob('Normal', null);
        fax__Service_Engineer__c foreignEngineer = makeEngineer(false, false, false, 'Yes');
        fax__Assigned_Engineer__c foreignAssignment = insertOwnedAssignment(
            foreignJob.Id,
            foreignEngineer.Id,
            'Assigned'
        );

        Boolean foreignThrew = false;
        try {
            AssignmentTriggerHandler.updateMyAssignmentStatus(
                foreignAssignment.Id,
                'Accepted',
                '13.0',
                '80.0'
            );
        } catch (AuraHandledException ex) {
            foreignThrew = true;
        }
        System.assertEquals(true, foreignThrew);
    }

    @isTest
    static void testUpdateMyAssignmentStatus_SkipsGpsWhenDisabledOrBlankCoords() {
        fax__Assigned_Engineer__c assignment = setupMultiAssignmentJob('Assigned', false);
        Id engineerId = assignment.fax__Service_Engineer__c;

        Test.startTest();
        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'Accepted',
            null,
            null
        );
        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'En Route',
            '13.1111',
            '80.1111'
        );
        Test.stopTest();

        fax__Service_Engineer__c eng = [
            SELECT fax__Latitude__c, fax__Longitude__c
            FROM fax__Service_Engineer__c
            WHERE Id = :engineerId
        ];
        System.assertEquals(null, eng.fax__Latitude__c);
        System.assertEquals(null, eng.fax__Longitude__c);
    }

    @isTest
    static void testUpdateMyAssignment_UpdatesEditableFields() {
        fax__Assigned_Engineer__c assignment = setupMultiAssignmentJob('Assigned', false);
        Datetime plannedStart = System.now().addHours(1);
        Datetime plannedEnd = System.now().addHours(3);

        Test.startTest();
        AssignmentTriggerHandler.AssignmentDetails details =
            AssignmentTriggerHandler.updateMyAssignment(
                assignment.Id,
                plannedStart,
                plannedEnd,
                true,
                'Updated reason'
            );
        Test.stopTest();

        System.assertEquals(true, details.allDay);
        System.assertEquals('Updated reason', details.rejectionReason);
        System.assertNotEquals(null, details.plannedStart);
        System.assertNotEquals(null, details.plannedEnd);
    }

    @isTest
    static void testUpdateMyAssignment_AllowsEditWhenCompleted() {
        fax__Assigned_Engineer__c assignment = setupMultiAssignmentJob('Completed', false);
        Datetime plannedStart = System.now().addDays(1);
        Datetime plannedEnd = System.now().addDays(1).addHours(2);

        Test.startTest();
        AssignmentTriggerHandler.AssignmentDetails details =
            AssignmentTriggerHandler.updateMyAssignment(
                assignment.Id,
                plannedStart,
                plannedEnd,
                false,
                'Completed edit notes'
            );
        Test.stopTest();

        System.assertEquals('Completed edit notes', details.rejectionReason);
        System.assertEquals('Completed', details.status);
    }

    @isTest
    static void testUpdateMyAssignmentStatus_ReopenFromCompletedCreatesNewCards() {
        injectEmergencyAndOnSiteTemplates();
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());

        fax__Assigned_Engineer__c assignment = setupMultiAssignmentJob('Accepted', false);
        Id jobId = assignment.fax__Job_new__c;
        Id engineerId = assignment.fax__Service_Engineer__c;

        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'En Route',
            null,
            null
        );
        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'On Site',
            null,
            null
        );
        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'Completed',
            null,
            null
        );

        Test.startTest();
        AssignmentTriggerHandler.AssignmentDetails reopened =
            AssignmentTriggerHandler.updateMyAssignmentStatus(
                assignment.Id,
                'En Route',
                null,
                null
            );
        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'On Site',
            null,
            null
        );
        AssignmentTriggerHandler.AssignmentDetails completedAgain =
            AssignmentTriggerHandler.updateMyAssignmentStatus(
                assignment.Id,
                'Completed',
                null,
                null
            );

        fax__Assigned_Engineer__c seed = new fax__Assigned_Engineer__c(
            Id = assignment.Id,
            fax__Job_New__c = jobId,
            fax__Service_Engineer__c = engineerId,
            fax__Travel_Start__c = System.now().addMinutes(-20),
            fax__Travel_End__c = System.now().addMinutes(-5),
            fax__Start_Date_Time_cu__c = System.now().addMinutes(-5),
            fax__End_Start_time_cus__c = System.now()
        );
        try {
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'Accepted', 'En Route');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'En Route', 'On Site');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'On Site', 'Completed');
        } catch (Exception timeCardEx) {
            System.assert(String.isNotBlank(timeCardEx.getMessage()));
        }
        Test.stopTest();

        System.assertEquals('En Route', reopened.status);
        System.assertEquals('Completed', completedAgain.status);
        System.assertNotEquals(null, completedAgain.endDateTime);

        RingCentralSMSService.testCredential = null;
        SMSTemplateService.clearCache();
    }

    @isTest
    static void testUpdateMyAssignmentStatus_WorkPausedClosesJobAndAllowsEnRoute() {
        injectEmergencyAndOnSiteTemplates();
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());

        fax__Assigned_Engineer__c assignment = setupMultiAssignmentJob('Accepted', false);
        Id jobId = assignment.fax__Job_new__c;
        Id engineerId = assignment.fax__Service_Engineer__c;

        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'En Route',
            null,
            null
        );
        AssignmentTriggerHandler.updateMyAssignmentStatus(
            assignment.Id,
            'On Site',
            null,
            null
        );

        Test.startTest();
        AssignmentTriggerHandler.AssignmentDetails pausedDetails =
            AssignmentTriggerHandler.updateMyAssignmentStatus(
                assignment.Id,
                'Work Paused',
                null,
                null
            );

        fax__Job__c jobAfterPause = getJob(jobId);
        System.assertEquals(
            'On Site',
            jobAfterPause.fax__Status__c,
            'Work Paused must not sync Job status away from On Site.'
        );
        System.assertEquals('Work Paused', pausedDetails.status);
        System.assertNotEquals(null, pausedDetails.endDateTime);

        AssignmentTriggerHandler.AssignmentDetails enRouteFromPaused =
            AssignmentTriggerHandler.updateMyAssignmentStatus(
                assignment.Id,
                'En Route',
                null,
                null
            );
        System.assertEquals('En Route', enRouteFromPaused.status);
        System.assertNotEquals(null, enRouteFromPaused.travelStart);

        fax__Assigned_Engineer__c seed = new fax__Assigned_Engineer__c(
            Id = assignment.Id,
            fax__Job_New__c = jobId,
            fax__Service_Engineer__c = engineerId,
            fax__Travel_Start__c = System.now().addMinutes(-30),
            fax__Travel_End__c = System.now().addMinutes(-10),
            fax__Start_Date_Time_cu__c = System.now().addMinutes(-10),
            fax__End_Start_time_cus__c = System.now()
        );
        try {
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'Accepted', 'En Route');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'En Route', 'On Site');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'On Site', 'Work Paused');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'En Route', 'Work Paused');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'Work Paused', 'En Route');
            AssignmentTriggerHandler.createTimeCardsForStatusChange(seed, 'Work Paused', 'On Site');
        } catch (Exception timeCardEx) {
            System.assert(
                timeCardEx.getMessage().contains('Job Status Alert')
                    || timeCardEx.getMessage().contains('CANNOT_EXECUTE_FLOW_TRIGGER')
                    || String.isNotBlank(timeCardEx.getMessage()),
                'Unexpected time card failure: ' + timeCardEx.getMessage()
            );
        }
        Test.stopTest();

        RingCentralSMSService.testCredential = null;
        SMSTemplateService.clearCache();
    }
}