@isTest
private class JobAssignmentControllerTest {

    private static fax__Service_Engineer__c makeCurrentUserEngineer(Boolean gpsEnabled, String activeVal) {
        fax__Service_Engineer__c engineer = new fax__Service_Engineer__c(
            Name = 'Job Assignment Test Engineer',
            fax__Salesforce_user__c = UserInfo.getUserId(),
            fax__Enable_GPS_Tracking__c = gpsEnabled,
            fax__Active__c = activeVal
        );
        insert engineer;
        return engineer;
    }

    private static fax__Job__c makeJob(Id accountId) {
        Contact siteContact = new Contact(
            LastName = 'JA Test Contact',
            Email = 'job.assignment.test@example.com',
            AccountId = accountId
        );
        insert siteContact;

        fax__Job__c job = new fax__Job__c(
            fax__Customer__c = accountId,
            fax__Contact__c = siteContact.Id,
            fax__Planned_Visit_Date_Time__c = System.now(),
            fax__Status__c = 'Assigned',
            fax__Visit_Type__c = 'Service'
        );
        insert job;
        return job;
    }

    @isTest
    static void testGetMyAssignmentContext_NotVisibleWithSingleAssignment() {
        Account acc = new Account(Name = 'Job Assignment Single Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Job__c job = makeJob(acc.Id);

        insert new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Assigned'
        );

        Test.startTest();
        JobAssignmentController.AssignmentContext context =
            JobAssignmentController.getMyAssignmentContext(job.Id);
        Test.stopTest();

        System.assertEquals(false, context.isVisible);
        System.assertEquals(1, context.assignmentCount);
    }

    @isTest
    static void testGetMyAssignmentContext_VisibleWithMultipleAssignments() {
        Account acc = new Account(Name = 'Job Assignment Multi Account');
        insert acc;
        fax__Service_Engineer__c currentEngineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Other Engineer');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        insert new List<fax__Assigned_Engineer__c>{
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = currentEngineer.Id,
                fax__Status__c = 'Assigned'
            ),
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        Test.startTest();
        JobAssignmentController.AssignmentContext context =
            JobAssignmentController.getMyAssignmentContext(job.Id);
        Test.stopTest();

        System.assertEquals(true, context.isVisible);
        System.assertEquals(2, context.assignmentCount);
        System.assertNotEquals(null, context.assignment);
        System.assertEquals('Assigned', context.assignment.status);
        System.assert(!context.statusOptions.isEmpty());
        System.assertEquals(2, context.allAssignments.size());
        System.assertEquals(true, context.allAssignments[0].isOwnAssignment || context.allAssignments[1].isOwnAssignment);
    }

    @isTest
    static void testGetMyAssignmentContext_VisibleWhenOwnAssignmentCompleted() {
        Account acc = new Account(Name = 'Job Assignment Completed Account');
        insert acc;
        fax__Service_Engineer__c currentEngineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Completed Other Engineer');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        insert new List<fax__Assigned_Engineer__c>{
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = currentEngineer.Id,
                fax__Status__c = 'Completed'
            ),
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'On Site'
            )
        };

        Test.startTest();
        JobAssignmentController.AssignmentContext context =
            JobAssignmentController.getMyAssignmentContext(job.Id);
        Test.stopTest();

        System.assertEquals(true, context.isVisible);
        System.assertEquals('Completed', context.assignment.status);
        System.assertEquals(true, context.canEditOwnAssignment);

        Boolean foundOwnReadOnly = false;
        for (JobAssignmentController.AssignmentSummary summary : context.allAssignments) {
            if (summary.isOwnAssignment) {
                foundOwnReadOnly = true;
                System.assertEquals(true, summary.isEditable);
            }
        }
        System.assertEquals(true, foundOwnReadOnly);
    }

    @isTest
    static void testUpdateMyAssignmentStatus_AllTransitionsWithGeolocation() {
        Account acc = new Account(Name = 'Job Assignment Status Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(true, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Status Other Engineer');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Assigned'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        Test.startTest();
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'Accepted', '13.5678', '80.1234');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'En Route', '13.6000', '80.2000');
        JobAssignmentController.AssignmentDetails details =
            JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.7000', '80.3000');
        Test.stopTest();

        System.assertEquals('On Site', details.status);
        System.assertNotEquals(null, details.travelStart);
        System.assertNotEquals(null, details.travelEnd);
        System.assertNotEquals(null, details.startDateTime);

        engineer = [
            SELECT fax__Latitude__c, fax__Longitude__c
            FROM fax__Service_Engineer__c
            WHERE Id = :engineer.Id
        ];
        System.assertEquals('13.7000', String.valueOf(engineer.fax__Latitude__c));
        System.assertEquals('80.3000', String.valueOf(engineer.fax__Longitude__c));
    }

    @isTest
    static void testUpdateMyAssignmentStatus_CreatesTravelTimeCardOnOnSite() {
        Account acc = new Account(Name = 'Time Card Status Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(true, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Time Card Other');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Accepted'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        Test.startTest();
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'En Route', '13.6000', '80.2000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.7000', '80.3000');
        Test.stopTest();

        List<fax__Time_Card__c> travelCards = [
            SELECT Id, fax__Time_for__c, fax__Hours__c, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Travel'
            ORDER BY CreatedDate DESC
        ];
        List<fax__Time_Card__c> jobCards = [
            SELECT Id, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Job'
            ORDER BY CreatedDate DESC
        ];
        System.assert(!travelCards.isEmpty(), 'On Site must leave a Travel session card.');
        System.assertEquals('Travel', travelCards[0].fax__Time_for__c);
        System.assertNotEquals(null, travelCards[0].fax__Timer_End__c, 'On Site should close Travel.');
        System.assert(!jobCards.isEmpty(), 'On Site should insert open Job card.');
        System.assertEquals(null, jobCards[0].fax__Timer_End__c, 'Job card stays open until Completed.');
        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM fax__Time_Card__c
                WHERE fax__Job2__c = :job.Id
                AND fax__Service_Engineer__c = :engineer.Id
                AND fax__Time_for__c = 'Travel'
                AND fax__Timer_End__c = null
            ],
            'No open Travel timer should remain after On Site.'
        );
    }

    @isTest
    static void testUpdateMyAssignmentStatus_OtherUsersAssignmentThrows() {
        Account acc = new Account(Name = 'Job Assignment Security Account');
        insert acc;
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Protected Engineer');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = otherEngineer.Id,
            fax__Status__c = 'Assigned'
        );
        insert assignment;

        Boolean didThrow = false;
        try {
            JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'Accepted', '13.0000', '80.0000');
        } catch (AuraHandledException ex) {
            didThrow = true;
        }
        System.assertEquals(true, didThrow);
    }

    @isTest
    static void testUpdateMyAssignment_UpdatesEditableFields() {
        Account acc = new Account(Name = 'Job Assignment Edit Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Edit Other Engineer');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Assigned'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        Datetime plannedStart = System.now().addHours(1);
        Datetime plannedEnd = System.now().addHours(3);

        Test.startTest();
        JobAssignmentController.AssignmentDetails details = JobAssignmentController.updateMyAssignment(
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
    static void testGetMyAssignmentContext_ReturnsOtherAssignmentsReadOnly() {
        Account acc = new Account(Name = 'Job Assignment Others Account');
        insert acc;
        fax__Service_Engineer__c currentEngineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Read Only Engineer');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        insert new List<fax__Assigned_Engineer__c>{
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = currentEngineer.Id,
                fax__Status__c = 'Accepted'
            ),
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'En Route'
            )
        };

        Test.startTest();
        JobAssignmentController.AssignmentContext context =
            JobAssignmentController.getMyAssignmentContext(job.Id);
        Test.stopTest();

        Integer otherCount = 0;
        for (JobAssignmentController.AssignmentSummary summary : context.allAssignments) {
            if (!summary.isOwnAssignment) {
                otherCount++;
                System.assertEquals('En Route', summary.status);
                System.assertEquals('Read Only Engineer', summary.engineerName);
            }
        }
        System.assertEquals(1, otherCount);
    }

    @isTest
    static void testUpdateMyAssignment_AllowsEditWhenCompleted() {
        Account acc = new Account(Name = 'Job Assignment Completed Edit');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Completed Edit Other');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Completed'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        Datetime plannedStart = System.now().addDays(1);
        Datetime plannedEnd = System.now().addDays(1).addHours(2);

        Test.startTest();
        JobAssignmentController.AssignmentDetails details = JobAssignmentController.updateMyAssignment(
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
    static void testUpdateMyAssignmentStatus_AllowsChangeWhenCompleted() {
        Account acc = new Account(Name = 'Job Assignment Completed Status');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Completed Status Other');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Completed'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        Test.startTest();
        JobAssignmentController.AssignmentDetails details =
            JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.0000', '80.0000');
        Test.stopTest();

        System.assertEquals('On Site', details.status);
    }

    @isTest
    static void testUpdateMyAssignmentStatus_ReopenFromCompletedToOnSite() {
        Account acc = new Account(Name = 'Job Assignment Reopen Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Reopen Other Engineer');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Completed',
            fax__Start_Date_Time_cu__c = System.now().addDays(-1),
            fax__End_Start_time_cus__c = System.now().addDays(-1).addMinutes(30)
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        Test.startTest();
        JobAssignmentController.AssignmentDetails details =
            JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.0000', '80.0000');
        Test.stopTest();

        assignment = [
            SELECT fax__Status__c, fax__Start_Date_Time_cu__c, fax__End_Start_time_cus__c
            FROM fax__Assigned_Engineer__c
            WHERE Id = :assignment.Id
        ];
        System.assertEquals('On Site', details.status);
        System.assertEquals(null, assignment.fax__End_Start_time_cus__c);
        System.assertNotEquals(null, assignment.fax__Start_Date_Time_cu__c);
    }

    @isTest
    static void testSyncTimeCardsFromAssignment_CreatesTravelAndJobCards() {
        Account acc = new Account(Name = 'Time Card Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Time Card Other');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Accepted'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        Test.startTest();
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'En Route', '13.6000', '80.2000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.7000', '80.3000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'Completed', '13.7000', '80.3000');
        Test.stopTest();

        List<fax__Time_Card__c> travelCards = [
            SELECT fax__Time_for__c, fax__Hours__c, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Travel'
            ORDER BY CreatedDate DESC
        ];
        List<fax__Time_Card__c> jobCards = [
            SELECT fax__Time_for__c, fax__Hours__c, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Job'
            ORDER BY CreatedDate DESC
        ];

        System.assert(!travelCards.isEmpty(), 'Expected a Travel time card.');
        System.assert(!jobCards.isEmpty(), 'Expected a Job time card.');
        Boolean jobClosed = false;
        for (fax__Time_Card__c jobCard : jobCards) {
            if (jobCard.fax__Timer_End__c != null) {
                jobClosed = true;
                break;
            }
        }
        System.assert(jobClosed, 'Completed should close Job card.');
        System.assertNotEquals(null, travelCards[0].fax__Hours__c);
        System.assert(travelCards[0].fax__Hours__c >= 0);
    }

    @isTest
    static void testCreateTimeCards_CompletedDoesNotAlterExistingTravel() {
        Account acc = new Account(Name = 'Time Card Update Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Time Card Update Other');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Accepted'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'En Route', '13.6000', '80.2000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.7000', '80.3000');

        fax__Time_Card__c travelBefore = [
            SELECT Id, fax__Hours__c, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Travel'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        fax__Time_Card__c jobBefore = [
            SELECT Id, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Job'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assertEquals(null, jobBefore.fax__Timer_End__c, 'Job should be open after On Site.');

        Test.startTest();
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'Completed', '13.7000', '80.3000');
        Test.stopTest();

        fax__Time_Card__c travelAfter = [
            SELECT fax__Hours__c, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE Id = :travelBefore.Id
        ];
        List<fax__Time_Card__c> jobCards = [
            SELECT Id, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE Id = :jobBefore.Id
        ];

        System.assertEquals(1, jobCards.size(), 'Completed should update the existing Job card, not replace it.');
        System.assertNotEquals(null, jobCards[0].fax__Timer_End__c, 'Completed should close Job card.');
        System.assertEquals(travelBefore.fax__Hours__c, travelAfter.fax__Hours__c);
        System.assertEquals(travelBefore.fax__Timer_End__c, travelAfter.fax__Timer_End__c);
    }

    @isTest
    static void testSyncTimeCardsFromAssignment_CreatesSeparateCardOnReopen() {
        Account acc = new Account(Name = 'Time Card Reopen Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Time Card Reopen Other');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Accepted'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'En Route', '13.6000', '80.2000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.7000', '80.3000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'Completed', '13.7000', '80.3000');

        Integer travelCardsAfterFirstPass = [
            SELECT COUNT()
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Travel'
        ];
        Integer jobCardsAfterFirstPass = [
            SELECT COUNT()
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Job'
        ];
        System.assert(travelCardsAfterFirstPass >= 1, 'First pass should leave a Travel session.');
        System.assert(jobCardsAfterFirstPass >= 1, 'First pass should leave a Job session.');

        Test.startTest();
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'En Route', '13.7000', '80.3000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.7000', '80.3000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'Completed', '13.7000', '80.3000');
        Test.stopTest();

        List<fax__Time_Card__c> travelCards = [
            SELECT Id, fax__Timer_Start__c, fax__Timer_End__c, fax__Hours__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Travel'
            ORDER BY fax__Timer_Start__c
        ];
        List<fax__Time_Card__c> jobCards = [
            SELECT Id, fax__Timer_Start__c, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Job'
            ORDER BY fax__Timer_Start__c
        ];

        System.assert(
            travelCards.size() >= 2,
            'Choosing En Route again should create a separate Travel time card.'
        );
        System.assert(
            jobCards.size() >= 2,
            'Rework On Site should insert a new Job card; Completed updates that card.'
        );
        System.assertNotEquals(
            travelCards[0].fax__Timer_Start__c,
            travelCards[travelCards.size() - 1].fax__Timer_Start__c,
            'Each Travel session should have its own start time.'
        );
        System.assertNotEquals(null, jobCards[jobCards.size() - 1].fax__Timer_End__c);
        System.assertEquals(
            [
                SELECT fax__Travel_End__c
                FROM fax__Assigned_Engineer__c
                WHERE Id = :assignment.Id
            ].fax__Travel_End__c,
            [
                SELECT fax__Timer_End__c
                FROM fax__Time_Card__c
                WHERE fax__Job2__c = :job.Id
                AND fax__Service_Engineer__c = :engineer.Id
                AND fax__Time_for__c = 'Travel'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ].fax__Timer_End__c
        );
    }

    @isTest
    static void testUpdateMyAssignmentStatus_RemovesOpenFieldAxJobTimerAndInsertsJob() {
        Account acc = new Account(Name = 'FieldAx Timer Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'FieldAx Timer Other');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'Accepted'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'En Route', '13.6000', '80.2000');
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'On Site', '13.7000', '80.3000');

        assignment = [
            SELECT Id, fax__Start_Date_Time_cu__c
            FROM fax__Assigned_Engineer__c
            WHERE Id = :assignment.Id
        ];

        // FieldAX ClockInOut opens an extra Job timer while On Site.
        insert new fax__Time_Card__c(
            fax__Job2__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Time_for__c = 'Job',
            fax__Timer_Start__c = assignment.fax__Start_Date_Time_cu__c,
            fax__Timer_End__c = null,
            fax__Date__c = Date.today()
        );

        fax__Time_Card__c sessionJobBeforeComplete = [
            SELECT Id
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Job'
            AND fax__Timer_End__c = null
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];

        Test.startTest();
        JobAssignmentController.updateMyAssignmentStatus(assignment.Id, 'Completed', '13.7000', '80.3000');
        Test.stopTest();

        Integer openJobTimers = [
            SELECT COUNT()
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Job'
            AND fax__Timer_End__c = null
        ];
        List<fax__Time_Card__c> travelCards = [
            SELECT Id
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :job.Id
            AND fax__Service_Engineer__c = :engineer.Id
            AND fax__Time_for__c = 'Travel'
        ];
        List<fax__Time_Card__c> jobCards = [
            SELECT Id, fax__Timer_End__c, fax__Hours__c
            FROM fax__Time_Card__c
            WHERE Id = :sessionJobBeforeComplete.Id
        ];

        System.assertEquals(0, openJobTimers, 'Completed must leave no open FieldAX Job timer.');
        System.assert(!travelCards.isEmpty(), 'One Travel card from En Route / On Site.');
        System.assertEquals(1, jobCards.size(), 'Completed should update existing Job, not replace it.');
        System.assertNotEquals(null, jobCards[0].fax__Timer_End__c);
        System.assertNotEquals(null, jobCards[0].fax__Hours__c);
    }

    @isTest
    static void testToUserMessage_FormatsValidationMessage() {
        Account acc = new Account(Name = 'Validation Message Account');
        insert acc;
        fax__Service_Engineer__c engineer = makeCurrentUserEngineer(false, 'Yes');
        fax__Service_Engineer__c otherEngineer = new fax__Service_Engineer__c(Name = 'Validation Other');
        insert otherEngineer;
        fax__Job__c job = makeJob(acc.Id);

        fax__Assigned_Engineer__c assignment = new fax__Assigned_Engineer__c(
            fax__Job_new__c = job.Id,
            fax__Service_Engineer__c = engineer.Id,
            fax__Status__c = 'On Site'
        );
        insert new List<fax__Assigned_Engineer__c>{
            assignment,
            new fax__Assigned_Engineer__c(
                fax__Job_new__c = job.Id,
                fax__Service_Engineer__c = otherEngineer.Id,
                fax__Status__c = 'Assigned'
            )
        };

        assignment.fax__Start_Date_Time_cu__c = System.now();
        assignment.fax__End_Start_time_cus__c = System.now().addDays(-1);

        Boolean didThrow = false;
        String userMessage;

        try {
            update assignment;
        } catch (DmlException ex) {
            didThrow = true;
            userMessage = JobAssignmentController.toUserMessage(ex);
        }

        System.assertEquals(true, didThrow, 'Expected validation failure when end is before start.');
        System.assert(
            userMessage.contains('Actual end date cannot be less than the start date'),
            'Expected readable validation message but got: ' + userMessage
        );
        System.assert(
            !userMessage.contains('first error'),
            'Message should not include technical DML prefixes.'
        );
    }
}