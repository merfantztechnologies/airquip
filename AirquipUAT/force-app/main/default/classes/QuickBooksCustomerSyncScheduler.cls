public class QuickBooksCustomerSyncScheduler implements Schedulable {

    private static final Integer DEFAULT_BATCH_SIZE = 1;
    private static final String CONFIG_NAME = 'Account_Default';

    public void execute(SchedulableContext sc) {

        faxa__QuickBooks_Sync_Config__mdt config = getConfig();

        Boolean isSandbox = config != null ? config.faxa__Is_Sandbox__c : true;
        Integer batchSize = config != null && config.faxa__Batch_Size__c != null
            ? Integer.valueOf(config.faxa__Batch_Size__c)
            : DEFAULT_BATCH_SIZE;

        QuickBooksCustomerSyncBatch batch = new QuickBooksCustomerSyncBatch(isSandbox);
        Database.executeBatch(batch, batchSize);
    }

    private faxa__QuickBooks_Sync_Config__mdt getConfig() {
        List<faxa__QuickBooks_Sync_Config__mdt> configs = [
            SELECT faxa__Is_Sandbox__c, faxa__Batch_Size__c, faxa__Object_Name__c
            FROM faxa__QuickBooks_Sync_Config__mdt
            WHERE DeveloperName = :CONFIG_NAME
              AND faxa__Status__c = 'Active'
            LIMIT 1
        ];
        return configs.isEmpty() ? null : configs[0];
    }
}