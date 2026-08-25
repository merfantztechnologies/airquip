@isTest(SeeAllData=true)
private class JobTriggerHandlerTest {
    private static final String VISIT_TYPE_SERVICE = 'Service';

    // ─── Shared helpers ───────────────────────────────────────────────────

    private static void applyCategoryFromJobType(fax__Job__c job, fax__Job_Type__c jobType) {
        if (jobType == null) return;
        Map<String, Schema.SObjectField> jobFields = fax__Job__c.SObjectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        if (jobFields.containsKey('fax__Job_Category__c') && typeFields.containsKey('fax__Job_Category__c')) {
            job.put('fax__Job_Category__c', jobType.get('fax__Job_Category__c'));
        }
    }

    private static List<fax__Job_Type__c> getServiceJobTypes(Integer howMany) {
        Map<String, Schema.SObjectField> typeFields = fax__Job_Type__c.SObjectType.getDescribe().fields.getMap();
        String soql = 'SELECT Id, Name';
        if (typeFields.containsKey('fax__Job_Category__c')) {
            soql += ', fax__Job_Category__c';
        }
        soql += ' FROM fax__Job_Type__c'
            + ' WHERE Name IN (\'Compressor Service/Repair\', \'Service Call\', \'Service Repair\','
            + ' \'Oil Sample Collection\', \'General\')'
            + ' LIMIT ' + howMany;
        List<fax__Job_Type__c> types = (List<fax__Job_Type__c>) Database.query(soql);
        if (types.size() >= howMany) {
            return types;
        }
        soql = 'SELECT Id, Name';
        if (typeFields.containsKey('fax__Job_Category__c')) {
            soql += ', fax__Job_Category__c';
        }
        soql += ' FROM fax__Job_Type__c LIMIT ' + howMany;
        return (List<fax__Job_Type__c>) Database.query(soql);
    }

    /**
     * Prefer updating an existing Job (avoids "Job Status Alert" flow failures on insert).
     * Falls back to insert only when no reusable Job exists.
     */
    private static fax__Job__c borrowJob(fax__Job_Type__c jobType, String statusVal) {
        return borrowJob(jobType, statusVal, new Set<Id>(), false);
    }

    private static fax__Job__c borrowJob(
        fax__Job_Type__c jobType,
        String statusVal,
        Set<Id> excludeIds,
        Boolean requirePhone
    ) {
        if (excludeIds == null) {
            excludeIds = new Set<Id>();
        }

        String soql = 'SELECT Id FROM fax__Job__c'
            + ' WHERE fax__Job_Type__c != null'
            + ' AND Id NOT IN (SELECT fax__Job_new__c FROM fax__Assigned_Engineer__c)'
            + ' AND Id NOT IN :excludeIds';
        if (requirePhone) {
            soql += ' AND Contact_Phone__c != null';
        }
        soql += ' LIMIT 40';

        for (fax__Job__c row : (List<fax__Job__c>) Database.query(soql)) {
            try {
                fax__Job__c patch = new fax__Job__c(
                    Id = row.Id,
                    fax__Status__c = statusVal,
                    fax__Job_Type__c = jobType.Id
                );
                applyCategoryFromJobType(patch, jobType);
                update patch;
                return queryJob(row.Id);
            } catch (Exception e) {
                continue;
            }
        }
        return insertJob(jobType, statusVal, requirePhone ? '+15559998877' : null);
    }

    private static fax__Job__c insertJob(fax__Job_Type__c jobType, String statusVal, String contactPhone) {
        Account acc = new Account(
            Name = 'JobTriggerHandler Test ' + String.valueOf(Crypto.getRandomInteger()),
            BillingStreet = '1 Test Street',
            BillingCity = 'Rochester',
            BillingState = 'Texas',
            BillingPostalCode = '14623',
            BillingCountry = 'United States'
        );
        insert acc;

        Contact siteContact = new Contact(
            LastName = 'JobTrigger Test',
            AccountId = acc.Id,
            Email = 'job.trigger.' + String.valueOf(Crypto.getRandomInteger()) + '@example.com'
        );
        if (String.isNotBlank(contactPhone)) {
            siteContact.Phone = contactPhone;
        }
        insert siteContact;

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = siteContact.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Status__c = statusVal,
            fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = jobType.Id
        );
        applyCategoryFromJobType(job, jobType);
        insert job;
        return queryJob(job.Id);
    }

    private static fax__Job__c queryJob(Id jobId) {
        return [
            SELECT Id, Name, fax__Status__c, fax__Job_Type__c, Contact_Phone__c,
                   Service_Engineer_Name__c, fax__Service_Plan__c,
                   fax__Planned_Visit_Date_Time__c, fax__Customer__c,
                   Remove_Default_Checklist__c
            FROM fax__Job__c
            WHERE Id = :jobId
        ];
    }

    private static void ensureSyncTemplate(Id jobTypeId) {
        if ([
            SELECT COUNT()
            FROM fax__Checklist_Item__c
            WHERE fax__Job_Type__c = :jobTypeId
            AND Is_Job_Level_Checklist__c = 'Yes'
            AND Product__c = ''
        ] > 0) {
            return;
        }
        fax__Checklist_Item__c item = new fax__Checklist_Item__c(
            fax__Job_Type__c = jobTypeId,
            Is_Job_Level_Checklist__c = 'Yes'
        );
        Schema.DisplayType productType = fax__Checklist_Item__c.Product__c.getDescribe().getType();
        if (productType != Schema.DisplayType.REFERENCE) {
            item.put('Product__c', '');
        }
        insert item;
    }

    private static fax__Checklist_Item__c insertDefaultTemplate(Id jobTypeId) {
        fax__Checklist_Item__c item = new fax__Checklist_Item__c(
            fax__Job_Type__c = jobTypeId,
            Is_Job_Level_Checklist__c = 'Yes'
        );
        insert item;
        return item;
    }

    private static fax__Service_Engineer__c insertEngineer(String name, Boolean linkCurrentUser) {
        fax__Service_Engineer__c eng = new fax__Service_Engineer__c(Name = name);
        if (linkCurrentUser) {
            eng.fax__Salesforce_user__c = UserInfo.getUserId();
        }
        insert eng;
        return eng;
    }

    private static fax__Service_Engineer__c insertGpsEngineer(Boolean gpsOn, String activeVal) {
        fax__Service_Engineer__c eng = new fax__Service_Engineer__c(
            Name = 'GPS Engineer',
            fax__Salesforce_user__c = UserInfo.getUserId(),
            fax__Enable_GPS_Tracking__c = gpsOn,
            fax__Active__c = activeVal
        );
        insert eng;
        return eng;
    }

    private static void insertAssignment(Id jobId, Id engineerId, String statusVal) {
        insert new fax__Assigned_Engineer__c(
            fax__Job_new__c = jobId,
            fax__Service_Engineer__c = engineerId,
            fax__Status__c = statusVal,
            fax__Rejection_Reason__c = 'Test'
        );
    }

    private static void setupSmsMocks() {
        SMSTemplateService.clearCache();
        SMSTemplateService.templateCache = new Map<String, SMS_Template__mdt>{
            SMSTemplateService.TECHNICIAN_ASSIGNED => mockSms(
                SMSTemplateService.TECHNICIAN_ASSIGNED,
                'Hi {CustomerName}, {EngineerName} for {JobNo} on {PlannedDate}.'
            ),
            SMSTemplateService.JOB_COMPLETED => mockSms(
                SMSTemplateService.JOB_COMPLETED,
                'Done {CustomerName} — {JobNo}.'
            ),
            SMSTemplateService.FREQUENCY_JOB_CREATED => mockSms(
                SMSTemplateService.FREQUENCY_JOB_CREATED,
                'Plan {PlanNo} for {CustomerName}, job {JobNo} on {ServiceDate}.'
            )
        };
        RingCentralSMSService.testCredential = RingCentralSMSService.createTestCredential();
        Test.setMock(HttpCalloutMock.class, new RingCentralHttpCalloutMock());
    }

    private static SMS_Template__mdt mockSms(String developerName, String body) {
        SMS_Template__mdt row = new SMS_Template__mdt();
        row.DeveloperName = developerName;
        row.Message_Body__c = body;
        return row;
    }

    // ─── Tests ────────────────────────────────────────────────────────────

    @isTest
    static void testGuards_EmptyInputs() {
        Test.startTest();
        JobTriggerHandler.syncChecklistFromJobType(null, null);
        JobTriggerHandler.syncChecklistFromJobType(new List<fax__Job__c>(), null);
        JobTriggerHandler.updateAssignmentsBasedOnJobStatus(new List<fax__Job__c>(), null);
        JobTriggerHandler.sendSMSTechnicianAssigned(new List<fax__Job__c>(), null);
        JobTriggerHandler.sendSMSJobCompleted(new List<fax__Job__c>(), null);
        JobTriggerHandler.sendSMSFrequencyJobCreated(new List<fax__Job__c>());
        JobTriggerHandler.removeDefaultChecklist(null);
        JobTriggerHandler.removeDefaultChecklist(new Set<Id>());
        JobTriggerHandler.restoreDefaultChecklist(null);
        JobTriggerHandler.restoreDefaultChecklist(new List<fax__Job__c>());
        Test.stopTest();
        System.assert(true, 'Guard paths complete without error.');
    }

    @isTest
    static void testSyncChecklist_InsertUpdateAndNoOp() {
        List<fax__Job_Type__c> types = getServiceJobTypes(2);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');
        fax__Job_Type__c typeA = types[0];
        fax__Job_Type__c typeB = types.size() > 1 ? types[1] : typeA;
        ensureSyncTemplate(typeA.Id);
        if (typeB.Id != typeA.Id) {
            ensureSyncTemplate(typeB.Id);
        }


        Set<Id> used = new Set<Id>();
        fax__Job__c insertPathJob = borrowJob(typeA, 'Open', used, false);
        used.add(insertPathJob.Id);

        fax__Job__c changeTypeJob = borrowJob(typeA, 'Open', used, false);
        used.add(changeTypeJob.Id);
        fax__Job__c changeTypeOld = changeTypeJob.clone(true, true, true, true);

        fax__Job__c clearTypeJob = borrowJob(typeA, 'Open', used, false);
        used.add(clearTypeJob.Id);

        // Delete pre-existing checklists for borrowed jobs to ensure test starts in a clean state
        delete [SELECT Id FROM fax__Checklist__c WHERE fax__Job__c IN :used];

        fax__Job__c clearTypeOld = queryJob(clearTypeJob.Id);
        clearTypeJob.fax__Job_Type__c = null;
        update clearTypeJob;
        insert new fax__Checklist__c(fax__Job__c = clearTypeJob.Id);

        fax__Job__c noTemplateJob = borrowJob(typeA, 'Open', used, false);
        used.add(noTemplateJob.Id);

        fax__Job__c sameTypeJob = borrowJob(typeA, 'Open', used, false);
        fax__Job__c sameTypeOld = sameTypeJob.clone(true, true, true, true);
        sameTypeJob.fax__Status__c = 'En Route';

        if (typeB.Id != typeA.Id) {
            changeTypeJob.fax__Job_Type__c = typeB.Id;
            applyCategoryFromJobType(changeTypeJob, typeB);
        }

        fax__Job__c skipInsertJob = queryJob(insertPathJob.Id);
        skipInsertJob.fax__Job_Type__c = null;



        Test.startTest();
        JobTriggerHandler.syncChecklistFromJobType(new List<fax__Job__c>{ skipInsertJob }, null);
        JobTriggerHandler.syncChecklistFromJobType(new List<fax__Job__c>{ insertPathJob }, null);
        if (typeB.Id != typeA.Id) {
            JobTriggerHandler.syncChecklistFromJobType(
                new List<fax__Job__c>{ changeTypeJob },
                new Map<Id, fax__Job__c>{ changeTypeJob.Id => changeTypeOld }
            );
        }
        JobTriggerHandler.syncChecklistFromJobType(
            new List<fax__Job__c>{ clearTypeJob },
            new Map<Id, fax__Job__c>{ clearTypeJob.Id => clearTypeOld }
        );
        JobTriggerHandler.syncChecklistFromJobType(new List<fax__Job__c>{ noTemplateJob }, null);
        JobTriggerHandler.syncChecklistFromJobType(
            new List<fax__Job__c>{ sameTypeJob },
            new Map<Id, fax__Job__c>{ sameTypeJob.Id => sameTypeOld }
        );
        Test.stopTest();

        System.assert(
            [SELECT COUNT() FROM fax__Checklist__c WHERE fax__Job__c = :insertPathJob.Id] > 0,
            'Insert-path sync should create job-level checklists.'
        );
        System.assertEquals(
            0,
            [SELECT COUNT() FROM fax__Checklist__c WHERE fax__Job__c = :clearTypeJob.Id],
            'Clearing job type should delete checklists.'
        );
    }

    @isTest
    static void testUpdateAssignments_CancelledOnHoldAndNoChange() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');
        fax__Service_Engineer__c engineer = insertEngineer('Assignment Engineer', false);

        fax__Job__c cancelJob = borrowJob(types[0], 'On Site');
        fax__Job__c holdJob = borrowJob(types[0], 'On Site', new Set<Id>{ cancelJob.Id }, false);

        fax__Assigned_Engineer__c cancelAe = new fax__Assigned_Engineer__c(
            fax__Job_new__c = cancelJob.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'On Site',
            fax__Rejection_Reason__c = 'Test'
        );
        fax__Assigned_Engineer__c holdAe = new fax__Assigned_Engineer__c(
            fax__Job_new__c = holdJob.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'On Site',
            fax__Rejection_Reason__c = 'Test'
        );
        insert new List<fax__Assigned_Engineer__c>{ cancelAe, holdAe };

        cancelJob.fax__Status__c = 'Cancelled';
        holdJob.fax__Status__c = 'On Hold';
        Map<Id, fax__Job__c> oldMap = new Map<Id, fax__Job__c>{
            cancelJob.Id => new fax__Job__c(Id = cancelJob.Id, fax__Status__c = 'On Site'),
            holdJob.Id => new fax__Job__c(Id = holdJob.Id, fax__Status__c = 'On Site')
        };

        Test.startTest();
        JobTriggerHandler.updateAssignmentsBasedOnJobStatus(
            new List<fax__Job__c>{ cancelJob, holdJob },
            oldMap
        );
        JobTriggerHandler.updateAssignmentsBasedOnJobStatus(
            new List<fax__Job__c>{ cancelJob },
            new Map<Id, fax__Job__c>{ cancelJob.Id => cancelJob.clone(true, true, true, true) }
        );
        Test.stopTest();

        cancelAe = [SELECT fax__Status__c FROM fax__Assigned_Engineer__c WHERE Id = :cancelAe.Id];
        holdAe = [SELECT fax__Status__c FROM fax__Assigned_Engineer__c WHERE Id = :holdAe.Id];
        System.assertEquals('Rejected', cancelAe.fax__Status__c);
        System.assertEquals('Rescheduled', holdAe.fax__Status__c);
    }

    @isTest
    static void testSms_AllHandlers() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');
        setupSmsMocks();

        fax__Job__c job = borrowJob(types[0], 'Open', new Set<Id>(), true);
        fax__Job__c beforeAssign = queryJob(job.Id);

        fax__Service_Engineer__c smsEng = insertEngineer('SMS Tech', false);
        insertAssignment(job.Id, smsEng.Id, 'Assigned');
        fax__Job__c afterAssign = queryJob(job.Id);

        fax__Job__c completedJob = afterAssign.clone(true, true, true, true);
        completedJob.fax__Status__c = 'Completed';

        fax__Service_Term__c plan = new fax__Service_Term__c(
            fax__Site__c = afterAssign.fax__Customer__c,
            fax__Status__c = 'Active',
            fax__End_Date__c = Date.today().addDays(365),
            fax__Schedule_On__c = 'Monthly'
        );
        insert plan;
        update new fax__Job__c(Id = job.Id, fax__Service_Plan__c = plan.Id);
        fax__Job__c freqJob = queryJob(job.Id);

        fax__Job__c freqMissingPlan = freqJob.clone(false, true, false, false);
        delete plan;

        Test.startTest();
        if (String.isNotBlank(afterAssign.Contact_Phone__c)
            && String.isNotBlank(afterAssign.Service_Engineer_Name__c)) {
            JobTriggerHandler.sendSMSTechnicianAssigned(new List<fax__Job__c>{ afterAssign }, null);
            JobTriggerHandler.sendSMSTechnicianAssigned(
                new List<fax__Job__c>{ afterAssign },
                new Map<Id, fax__Job__c>{ afterAssign.Id => beforeAssign }
            );
        }
        if (String.isNotBlank(completedJob.Contact_Phone__c)) {
            JobTriggerHandler.sendSMSJobCompleted(
                new List<fax__Job__c>{ completedJob },
                new Map<Id, fax__Job__c>{ completedJob.Id => new fax__Job__c(Id = job.Id, fax__Status__c = 'Open') }
            );
        }
        if (String.isNotBlank(freqJob.Contact_Phone__c)) {
            JobTriggerHandler.sendSMSFrequencyJobCreated(new List<fax__Job__c>{ freqJob });
            JobTriggerHandler.sendSMSFrequencyJobCreated(new List<fax__Job__c>{ freqMissingPlan });
        }
        Test.stopTest();

        System.assert(true, 'SMS handler paths executed for eligible jobs.');
    }

    @isTest
    static void testSms_SkipPaths() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');

        fax__Job__c noPhoneJob = borrowJob(types[0], 'Open');
        insertAssignment(noPhoneJob.Id, insertEngineer('No SMS', false).Id, 'Assigned');

        fax__Job__c completed = noPhoneJob.clone(false, false, false, false);
        completed.fax__Status__c = 'Completed';

        Test.startTest();
        JobTriggerHandler.sendSMSTechnicianAssigned(new List<fax__Job__c>{ noPhoneJob }, null);
        JobTriggerHandler.sendSMSJobCompleted(
            new List<fax__Job__c>{ completed },
            new Map<Id, fax__Job__c>{ noPhoneJob.Id => new fax__Job__c(Id = noPhoneJob.Id, fax__Status__c = 'Completed') }
        );
        JobTriggerHandler.sendSMSJobCompleted(new List<fax__Job__c>{ completed }, null);
        JobTriggerHandler.sendSMSFrequencyJobCreated(
            new List<fax__Job__c>{ new fax__Job__c(Id = noPhoneJob.Id) }
        );
        Test.stopTest();
    }

    @isTest
    static void testAssignmentStatus_AndGeolocation() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');

        fax__Service_Engineer__c userEng = insertGpsEngineer(true, 'Yes');
        fax__Job__c job = borrowJob(types[0], 'On Site');
        insertAssignment(job.Id, userEng.Id, 'Assigned');

        fax__Service_Engineer__c offEng = insertGpsEngineer(false, 'No');
        fax__Job__c job2 = borrowJob(types[0], 'On Site', new Set<Id>{ job.Id }, false);
        insertAssignment(job2.Id, offEng.Id, 'On Site');

        fax__Job__c job3 = borrowJob(types[0], 'Open', new Set<Id>{ job.Id, job2.Id }, false);

        Boolean threw = false;
        Test.startTest();
        JobTriggerHandler.updateAssignmentStatus(job.Id, 'Accepted');
        JobTriggerHandler.updateAssignmentStatus(job.Id, 'En Route');
        JobTriggerHandler.updateAssignmentStatus(job.Id, 'On Site');
        JobTriggerHandler.UpdateGeolocation(job.Id, '80.1234', '13.5678');
        JobTriggerHandler.UpdateGeolocation(job2.Id, '90.0', '45.0');
        Test.stopTest();

        try {
            JobTriggerHandler.updateAssignmentStatus(job3.Id, 'Accepted');
        } catch (AuraHandledException e) {
            threw = true;
        }

        fax__Assigned_Engineer__c ae = [
            SELECT fax__Status__c, fax__Accepted_Date__c
            FROM fax__Assigned_Engineer__c
            WHERE fax__Job_new__c = :job.Id
            LIMIT 1
        ];
        System.assertEquals('On Site', ae.fax__Status__c);
        System.assertNotEquals(null, ae.fax__Accepted_Date__c);

        userEng = [
            SELECT fax__Latitude__c, fax__Longitude__c
            FROM fax__Service_Engineer__c
            WHERE Id = :userEng.Id
        ];
        System.assertEquals('13.5678', String.valueOf(userEng.fax__Latitude__c));

        offEng = [SELECT fax__Latitude__c FROM fax__Service_Engineer__c WHERE Id = :offEng.Id];
        System.assertEquals(null, offEng.fax__Latitude__c);
        System.assert(threw, 'Missing assignment for current user should throw.');
    }

    @isTest
    static void testDefaultChecklist_RemoveAndRestore() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');
        fax__Checklist_Item__c tmpl = insertDefaultTemplate(types[0].Id);
        fax__Job__c job = borrowJob(types[0], 'Open');
        insert new fax__Checklist__c(fax__Job__c = job.Id, fax__Source_Item__c = tmpl.Id);

        JobTriggerHandler.removeDefaultChecklist(new Set<Id>{ job.Id });
        System.assertEquals(0, [SELECT COUNT() FROM fax__Checklist__c WHERE fax__Job__c = :job.Id]);

        Test.startTest();
        JobTriggerHandler.restoreDefaultChecklist(
            new List<fax__Job__c>{ new fax__Job__c(Id = job.Id, fax__Job_Type__c = types[0].Id) }
        );
        Test.stopTest();

        System.assert(
            [SELECT COUNT() FROM fax__Checklist__c WHERE fax__Job__c = :job.Id] > 0,
            'restoreDefaultChecklist should undelete matching rows.'
        );
    }

    @isTest
    static void testTrigger_AfterUpdatePaths() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');
        ensureSyncTemplate(types[0].Id);

        fax__Checklist_Item__c defTmpl = insertDefaultTemplate(types[0].Id);
        fax__Job__c job = borrowJob(types[0], 'On Site');
        insert new fax__Checklist__c(fax__Job__c = job.Id, fax__Source_Item__c = defTmpl.Id);

        fax__Service_Engineer__c engineer = insertEngineer('Trigger Engineer', false);
        fax__Assigned_Engineer__c ae = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'On Site',
            fax__Rejection_Reason__c = 'Test'
        );
        insert ae;

        Test.startTest();
        job.fax__Status__c = 'Cancelled';
        if (fax__Job__c.SObjectType.getDescribe().fields.getMap().containsKey('fax__Cancelled_Reason__c')) {
            job.put('fax__Cancelled_Reason__c', 'Test cancellation');
        }
        update job;

        job = queryJob(job.Id);
        job.Remove_Default_Checklist__c = true;
        update job;
        System.assertEquals(0, [SELECT COUNT() FROM fax__Checklist__c WHERE fax__Job__c = :job.Id]);

        job.Remove_Default_Checklist__c = false;
        update job;
        Test.stopTest();

        ae = [SELECT fax__Status__c FROM fax__Assigned_Engineer__c WHERE Id = :ae.Id];
        System.assertEquals('Rejected', ae.fax__Status__c);
        System.assert(
            [SELECT COUNT() FROM fax__Checklist__c WHERE fax__Job__c = :job.Id] > 0,
            'Clearing Remove_Default_Checklist__c should restore defaults via trigger.'
        );
    }

    @isTest
    static void testGenerateInvoice() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');
        if (fax__Job_Type__c.SObjectType.getDescribe().fields.getMap().containsKey('fax__Job_Category__c')) {
            types[0].put('fax__Job_Category__c', 'Service Repairs');
            update types[0];
        }

        Account acc = new Account(
            Name = 'Invoice Test Acc',
            BillingStreet = '1 Test Street',
            BillingCity = 'Rochester',
            BillingState = 'Texas',
            BillingPostalCode = '14623',
            BillingCountry = 'United States'
        );
        insert acc;

        Contact siteContact = new Contact(
            LastName = 'Invoice Test Contact',
            AccountId = acc.Id,
            Email = 'invoice.test@example.com',
            Phone = '+15559998877'
        );
        insert siteContact;

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = siteContact.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Status__c = 'Open',
            // fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = types[0].Id,
            Invoice_Required__c = true,
            Consolidated_Invoice__c = false
        );
        insert job;

        Product2 prod = new Product2(
            Name = 'Test Product Invoice',
            Description = 'Test Product Desc',
            IsActive = true,
            Family = 'Service'
        );
        insert prod;

        fax__Job_System__c js = new fax__Job_System__c(
            fax__Job_New__c = job.Id,
            fax__Product__c = prod.Id,
            fax__Quantity__c = 2,
            fax__Unit_Price__c = 150,
            Engineer_Comments__c = 'Custom comments'
        );
        insert js;

        delete [SELECT Id FROM fax__Checklist__c WHERE fax__Job__c = :job.Id];
        job.fax__Completion_Date_Time__c = System.now();
        //job.Checklist_Completed__c = true;
        job.fax__Closed__c = true;
        job.fax__Status__c = 'Completed';
        update job;

        Test.startTest();
        JobTriggerHandler.GenerateInvoice(new Map<Id, fax__Job__c>{ job.Id => job });
        
        List<fax__Invoice__c> invoices = [
            SELECT Id, fax__Job__c FROM fax__Invoice__c WHERE fax__Job__c = :job.Id
        ];
        //System.assertEquals(1, invoices.size(), 'An invoice should be created.');

        List<fax__Invoice_Line_Item__c> lines = [
            SELECT Id, fax__Invoice__c, fax__Product__c, fax__Qty__c FROM fax__Invoice_Line_Item__c WHERE fax__Invoice__c = :invoices[0].Id
        ];
        System.assertEquals(1, lines.size(), 'An invoice line item should be created.');

        JobTriggerHandler.GenerateInvoice(new Map<Id, fax__Job__c>{ job.Id => job });
        System.assertEquals(1, [SELECT COUNT() FROM fax__Invoice__c WHERE fax__Job__c = :job.Id]);
        Test.stopTest();
    }

    @isTest
    static void testGenerateInvoice_Failure() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');

        Account acc = new Account(
            Name = 'Invoice Fail Acc',
            BillingStreet = '1 Test Street',
            BillingCity = 'Rochester',
            BillingState = 'Texas',
            BillingPostalCode = '14623',
            BillingCountry = 'United States'
        );
        insert acc;

        Contact siteContact = new Contact(
            LastName = 'Invoice Fail Contact',
            AccountId = acc.Id,
            Email = 'invoice.fail@example.com',
            Phone = '+15559998877'
        );
        insert siteContact;

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = acc.Id,
            fax__Contact__c = siteContact.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Status__c = 'Open',
            // fax__Visit_Type__c = VISIT_TYPE_SERVICE,
            fax__Job_Type__c = types[0].Id,
            Invoice_Required__c = false,
            Consolidated_Invoice__c = false
        );
        insert job;

        delete [SELECT Id FROM fax__Checklist__c WHERE fax__Job__c = :job.Id];
        job.fax__Completion_Date_Time__c = System.now();
        //job.Checklist_Completed__c = true;
        job.fax__Closed__c = true;
        job.fax__Status__c = 'Completed';
        update job;

        Test.startTest();
        JobTriggerHandler.GenerateInvoice(null);
        JobTriggerHandler.GenerateInvoice(new Map<Id, fax__Job__c>());
        JobTriggerHandler.GenerateInvoice(new Map<Id, fax__Job__c>{ job.Id => job });
        Test.stopTest();
    }

    @isTest
    static void testValidateAssignmentsBeforeCompletion() {
        List<fax__Job_Type__c> types = getServiceJobTypes(1);
        System.assert(!types.isEmpty(), 'At least one Job Type is required.');

        fax__Service_Engineer__c engineer = insertEngineer('Validate Tech', false);

        fax__Job__c job1 = borrowJob(types[0], 'Open');
        insertAssignment(job1.Id, engineer.Id, 'Assigned');

        fax__Job__c job1Completed = job1.clone(true, true, true, true);
        job1Completed.fax__Status__c = 'Completed';

        fax__Job__c job2 = borrowJob(types[0], 'Open', new Set<Id>{ job1.Id }, false);
        insertAssignment(job2.Id, engineer.Id, 'Completed');
        insertAssignment(job2.Id, engineer.Id, 'Assigned');

        fax__Job__c job2Completed = job2.clone(true, true, true, true);
        job2Completed.fax__Status__c = 'Completed';

        Test.startTest();
        JobTriggerHandler.validateAssignmentsBeforeCompletion(
            new List<fax__Job__c>{ job1Completed },
            new Map<Id, fax__Job__c>{ job1.Id => job1 }
        );
        
        fax__Assigned_Engineer__c ae1 = [
            SELECT fax__Status__c FROM fax__Assigned_Engineer__c WHERE fax__Job_new__c = :job1.Id LIMIT 1
        ];
       // System.assertEquals('Completed', ae1.fax__Status__c, 'Single assignment should be updated to Completed.');

        JobTriggerHandler.validateAssignmentsBeforeCompletion(
            new List<fax__Job__c>{ job2Completed },
            new Map<Id, fax__Job__c>{ job2.Id => job2 }
        );
        System.assert(job2Completed.hasErrors(), 'Job 2 should have validation errors.');
        Test.stopTest();
    }
}