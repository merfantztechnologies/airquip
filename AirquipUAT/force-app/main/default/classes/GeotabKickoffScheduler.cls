/**
 * One-time kickoff: device batch sync, location sync, then recurring scheduler.
 */
public class GeotabKickoffScheduler implements Schedulable {

  public void execute(SchedulableContext context) {
    if (!GeotabApiService.isIntegrationActive()) {
      return;
    }

    GeotabDeviceSyncScheduler.executeDeviceSyncBatch();
    GeotabDeviceSyncScheduler.scheduleHourly();

    GeotabLocationSyncScheduler.enqueueLocationSync();
    GeotabLocationSyncScheduler.scheduleFromConfig();
  }
}