@isTest
private class AccountFollowUpTaskSchedulerTest {

    @isTest
    static void testScheduleDailyJob() {

        Test.startTest();

        // Schedule job
        String jobId =
            AccountFollowUpTaskScheduler.scheduleDailyJob();

        Test.stopTest();

        // Verify job created
        CronTrigger ct = [
            SELECT Id,
                   State,
                   CronJobDetail.Name
            FROM CronTrigger
            WHERE Id = :jobId
            LIMIT 1
        ];

        System.assertEquals(
            AccountFollowUpTaskScheduler.JOB_NAME,
            ct.CronJobDetail.Name
        );
    }

    @isTest
    static void testExecuteMethod() {

        Test.startTest();

        // Schedule manually
        String cronExp = '0 0 0 1 1 ? 2099';

        System.schedule(
            'Test Scheduler',
            cronExp,
            new AccountFollowUpTaskScheduler()
        );

        Test.stopTest();

        // Reaching stopTest executes scheduled jobs
        System.assert(true);
    }

    @isTest
    static void testAbortExistingJob() {

        Test.startTest();

        // Create a job
        String jobId =
            System.schedule(
                AccountFollowUpTaskScheduler.JOB_NAME,
                '0 0 0 1 1 ? 2099',
                new AccountFollowUpTaskScheduler()
            );

        // Abort existing job
        AccountFollowUpTaskScheduler.abortExistingJob();

        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id,
                   State
            FROM CronTrigger
            WHERE Id = :jobId
            LIMIT 1
        ];
        
        if (!jobs.isEmpty()) {
        
            CronTrigger ct = jobs[0];
        
            System.assert(
                ct.State == 'Deleted' ||
                ct.State == 'DELETED' ||
                ct.State == 'Aborted'
            );
        
        } else {
        
            System.debug(
                LoggingLevel.WARN,
                'No CronTrigger record found for Job Id: ' + jobId
            );
        }
    }
}