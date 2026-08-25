/**
 * Runs hourly to stamp SLA_Breached__c on open cases whose SLA resolution due date has passed.
 * Schedule via CaseSlaBreachStampScheduler.scheduleHourlyJob().
 */
public class CaseSlaBreachStampScheduler implements Schedulable {

    public static final String JOB_NAME = 'Case SLA Breach Stamp Hourly';
    private static final String HOURLY_CRON = '0 0 * * * ?';

    public void execute(SchedulableContext sc) {
        stampSlaBreaches();
    }

    public static Integer stampSlaBreaches() {
        List<Case> casesToUpdate = [
            SELECT Id
            FROM Case
            WHERE IsClosed = false
              AND SLA_Breached__c = false
              AND SLA_Resolution_Due__c != null
              AND SLA_Resolution_Due__c < :System.now()
        ];

        if (casesToUpdate.isEmpty()) {
            return 0;
        }

        for (Case caseRecord : casesToUpdate) {
            caseRecord.SLA_Breached__c = true;
        }

        update casesToUpdate;
        return casesToUpdate.size();
    }

    public static String scheduleHourlyJob() {
        abortExistingJob();
        return System.schedule(JOB_NAME, HOURLY_CRON, new CaseSlaBreachStampScheduler());
    }

    public static void abortExistingJob() {
        for (CronTrigger job : [
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name = :JOB_NAME
        ]) {
            System.abortJob(job.Id);
        }
    }
}