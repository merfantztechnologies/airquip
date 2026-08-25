@isTest
private class ContactFollowUpTaskBatchTest {
    @testSetup
    static void setupTestData() {
        Account accountA = new Account(Name = 'Contact Follow Up Test Account A');
        insert accountA;

        Account accountB = new Account(Name = 'Contact Follow Up Test Account B');
        insert accountB;

        Contact inactiveContactWithoutTask = new Contact(
            FirstName = 'Inactive',
            LastName = 'NoTask',
            AccountId = accountA.Id
        );
        Contact inactiveContactWithOpenTask = new Contact(
            FirstName = 'Inactive',
            LastName = 'HasTask',
            AccountId = accountA.Id
        );
        Contact activeContact = new Contact(
            FirstName = 'Active',
            LastName = 'Recent',
            AccountId = accountB.Id
        );
        insert new List<Contact>{inactiveContactWithoutTask, inactiveContactWithOpenTask, activeContact};

        Task activeContactTask = new Task(
            Subject = 'Recent Activity',
            Status = 'Completed',
            Priority = 'Normal',
            WhoId = activeContact.Id,
            OwnerId = accountB.OwnerId,
            ActivityDate = Date.today(),
            Description = 'Completed activity to update LastActivityDate.'
        );
        insert activeContactTask;

        Task openTask = new Task(
            Subject = 'Contact Follow Up Required',
            Status = 'In Progress',
            Priority = 'Normal',
            WhoId = inactiveContactWithOpenTask.Id,
            OwnerId = accountA.OwnerId,
            ActivityDate = Date.today().addDays(1),
            Description = 'Existing open follow-up task for inactive contact.'
        );
        insert openTask;

        Task completedTask = new Task(
            Subject = 'Contact Follow Up Required',
            Status = 'Completed',
            Priority = 'Normal',
            WhoId = inactiveContactWithoutTask.Id,
            OwnerId = accountA.OwnerId,
            ActivityDate = Date.today().addDays(1),
            Description = 'Completed follow-up task should not block new task creation.'
        );
        insert completedTask;
    }

    @isTest
    static void testBatchCreatesOnlyEligibleTask() {
        Test.startTest();
            Database.executeBatch(new ContactFollowUpTaskBatch(), 200);
        Test.stopTest();

        List<Task> createdTasks = [
            SELECT Id, Subject, Status, Priority, WhoId, OwnerId, ActivityDate, Description
            FROM Task
            WHERE Subject = 'Contact Follow Up Required'
              AND Status = 'Not Started'
        ];

        System.assertEquals(1, createdTasks.size(), 'Only one new follow-up task should be created for the eligible inactive contact.');
        Task createdTask = createdTasks[0];
        System.assertEquals('Normal', createdTask.Priority);
        System.assertEquals(Date.today().addDays(1), createdTask.ActivityDate);
        System.assertEquals('Contact has not had activity in the last 3 months. Please contact the customer and update the activity history.', createdTask.Description);
    }

    @isTest
    static void testSchedulerExecuteInvokesBatch() {
        Test.startTest();
            new ContactFollowUpTaskScheduler().execute(null);
        Test.stopTest();

        Integer newTasksCount = [
            SELECT count()
            FROM Task
            WHERE Subject = 'Contact Follow Up Required'
              AND Status = 'Not Started'
        ];

        System.assertEquals(1, newTasksCount, 'Scheduler execute should invoke the batch and create the follow-up task.');
    }

    @isTest
    static void testScheduleDailyJobCreatesCronTrigger() {
        Test.startTest();
            String jobId = ContactFollowUpTaskScheduler.scheduleDailyJob();
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Scheduled job ID should not be null.');

        CronTrigger scheduledJob = [
            SELECT Id, CronJobDetail.Name
            FROM CronTrigger
            WHERE Id = :jobId
            LIMIT 1
        ];

        System.assertEquals(ContactFollowUpTaskScheduler.JOB_NAME, scheduledJob.CronJobDetail.Name);
    }
}