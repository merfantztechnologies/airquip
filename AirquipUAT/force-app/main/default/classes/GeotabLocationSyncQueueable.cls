public class GeotabLocationSyncQueueable implements Queueable, Database.AllowsCallouts {

  public GeotabLocationSyncQueueable() {
  }

  public GeotabLocationSyncQueueable(Boolean chainFollowUp) {
    this();
  }

  public void execute(QueueableContext context) {
    if (!GeotabApiService.isIntegrationActive()) {
      return;
    }
    try {
      GeotabLocationSyncService.syncLatestLocations();
    } catch (Exception ex) {
      GeotabApiService.updateSyncStatus('Error', ex.getMessage());
    }
  }
}