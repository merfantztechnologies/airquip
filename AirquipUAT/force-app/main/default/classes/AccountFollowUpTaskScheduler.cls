public class AccountFollowUpTaskScheduler implements Schedulable {

    public static final String JOB_NAME = 'Account Follow Up Task Scheduler';

    // Runs every day at 8:00 AM
    public static final String DAILY_CRON = '0 0 8 * * ?';

    public void execute(SchedulableContext sc) {

        System.debug(
            LoggingLevel.INFO,
            'AccountFollowUpTaskScheduler execute: starting batch job.'
        );

        Database.executeBatch(
            new AccountFollowUpTaskBatch(),
            200
        );
    }

    public static String scheduleDailyJob() {

        abortExistingJob();

        System.debug(
            LoggingLevel.INFO,
            'AccountFollowUpTaskScheduler scheduleDailyJob: scheduling job ' +
            JOB_NAME
        );

        return System.schedule(
            JOB_NAME,
            DAILY_CRON,
            new AccountFollowUpTaskScheduler()
        );
    }

    public static void abortExistingJob() {

        for (
            CronTrigger job :
            [
                SELECT Id, State
                FROM CronTrigger
                WHERE CronJobDetail.Name = :JOB_NAME
                AND State != 'DELETED'
            ]
        ) {

            try {

                System.abortJob(job.Id);

                System.debug(
                    LoggingLevel.INFO,
                    'AccountFollowUpTaskScheduler abortExistingJob: aborted existing job ' +
                    job.Id
                );

            } catch (Exception ex) {

                System.debug(
                    LoggingLevel.WARN,
                    'AccountFollowUpTaskScheduler abortExistingJob: unable to abort job ' +
                    job.Id +
                    ' | ' +
                    ex.getMessage()
                );
            }
        }
    }
}