/**
 * Schedules recurring Geotab location sync via Queueable.
 * Salesforce cron requires fixed integer minute values, so sub-hour cadences are
 * represented by multiple minute-offset jobs generated from metadata.
 */
public class GeotabLocationSyncScheduler implements Schedulable {

  public static final String JOB_NAME = 'Geotab Location Sync';
  private static final Integer MIN_SECONDS = 60;
  private static final Integer MINUTES_PER_HOUR = 60;
  private static final Integer MAX_SCHEDULED_APEX_JOBS = 100;

  @TestVisible
  private static String testCronExpression;

  public class ScheduleDefinition {
    public String jobName;
    public String cronExpression;

    public ScheduleDefinition(String jobName, String cronExpression) {
      this.jobName = jobName;
      this.cronExpression = cronExpression;
    }
  }

  public void execute(SchedulableContext context) {
    if (!GeotabApiService.isIntegrationActive()) {
      return;
    }
    enqueueLocationSync();
  }

  public static void scheduleFromConfig() {
    abortExistingJobs();
    Geotab_Integration_Config__mdt config = GeotabApiService.getActiveConfig();
    if (config == null) {
      return;
    }
    Integer intervalSeconds = config.Sync_Interval_Seconds__c != null
      ? Integer.valueOf(config.Sync_Interval_Seconds__c.intValue())
      : 60;
    List<ScheduleDefinition> schedules = testCronExpression != null
      ? new List<ScheduleDefinition>{ new ScheduleDefinition(JOB_NAME, testCronExpression) }
      : buildScheduleDefinitions(intervalSeconds);
    ensureScheduleCapacity(schedules.size());
    for (ScheduleDefinition schedule : schedules) {
      System.schedule(schedule.jobName, schedule.cronExpression, new GeotabLocationSyncScheduler());
    }
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

  public static void enqueueLocationSync() {
    if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
      System.enqueueJob(new GeotabLocationSyncQueueable());
    }
  }

  @TestVisible
  private static String buildCron(Integer intervalSeconds) {
    return buildScheduleDefinitions(intervalSeconds)[0].cronExpression;
  }

  @TestVisible
  private static List<ScheduleDefinition> buildScheduleDefinitions(Integer intervalSeconds) {
    Integer cadenceMinutes = normalizeCadenceMinutes(intervalSeconds);
    List<ScheduleDefinition> schedules = new List<ScheduleDefinition>();
    for (Integer minute = 0; minute < MINUTES_PER_HOUR; minute += cadenceMinutes) {
      String minuteText = formatMinute(minute);
      String jobName = cadenceMinutes == MINUTES_PER_HOUR ? JOB_NAME : JOB_NAME + ' ' + minuteText;
      schedules.add(new ScheduleDefinition(jobName, '0 ' + String.valueOf(minute) + ' * * * ?'));
    }
    return schedules;
  }

  private static Integer normalizeCadenceMinutes(Integer intervalSeconds) {
    if (intervalSeconds == null || intervalSeconds <= MIN_SECONDS) {
      return 1;
    }
    Integer cadenceMinutes = (intervalSeconds + MIN_SECONDS - 1) / MIN_SECONDS;
    if (cadenceMinutes > MINUTES_PER_HOUR || Math.mod(MINUTES_PER_HOUR, cadenceMinutes) != 0) {
      throw new GeotabApiService.GeotabApiException(
        'Geotab sync interval must resolve to a minute cadence that evenly divides one hour.'
      );
    }
    return cadenceMinutes;
  }

  private static void ensureScheduleCapacity(Integer schedulesToCreate) {
    Integer existingJobs = [
      SELECT COUNT()
      FROM CronTrigger
      WHERE State != 'DELETED'
    ];
    if (existingJobs + schedulesToCreate > MAX_SCHEDULED_APEX_JOBS) {
      throw new GeotabApiService.GeotabApiException(
        'Scheduling Geotab location sync requires ' + schedulesToCreate
        + ' jobs, but only ' + (MAX_SCHEDULED_APEX_JOBS - existingJobs)
        + ' scheduled Apex slots are available.'
      );
    }
  }

  private static String formatMinute(Integer minute) {
    return minute < 10 ? '0' + String.valueOf(minute) : String.valueOf(minute);
  }
}