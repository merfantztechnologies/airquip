/**
 * Schedules recurring Geotab device-to-vehicle batch sync (default: every hour).
 */
public class GeotabDeviceSyncScheduler implements Schedulable {

  public static final String JOB_NAME = 'Geotab Device Sync';
  public static final String CRON_HOURLY = '0 0 * * * ?';

  @TestVisible
  private static String testCronExpression;

  public void execute(SchedulableContext context) {
    executeDeviceSyncBatch();
  }

  public static void executeDeviceSyncBatch() {
    if (!GeotabApiService.isIntegrationActive()) {
      return;
    }
    Geotab_Integration_Config__mdt config = GeotabApiService.getActiveConfig();
    if (config == null || config.Device_Sync_Enabled__c != true) {
      return;
    }
    Integer batchSize = config.Device_Sync_Batch_Size__c != null
      ? Integer.valueOf(config.Device_Sync_Batch_Size__c.intValue())
      : 50;
    Database.executeBatch(new GeotabDeviceSyncBatch(), batchSize);
  }

  public static void scheduleHourly() {
    abortExistingJobs();
    if (!GeotabApiService.isIntegrationActive()) {
      return;
    }
    String cronExpression = testCronExpression != null ? testCronExpression : CRON_HOURLY;
    System.schedule(JOB_NAME, cronExpression, new GeotabDeviceSyncScheduler());
  }

  public static void abortExistingJobs() {
    String jobNamePattern = JOB_NAME + '%';
    for (CronTrigger job : [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE :jobNamePattern
    ]) {
      System.abortJob(job.Id);
    }
  }
}