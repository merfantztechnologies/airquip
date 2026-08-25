public class AccountFollowUpTaskBatch implements Database.Batchable<Account> {

    // Subject used for all follow-up tasks created by this batch
    public static final String TASK_SUBJECT = 'Call';

    // Default task values
    public static final String TASK_STATUS = 'Not Started';
    public static final String TASK_PRIORITY = 'Normal';

    // Number of days used to determine account inactivity
    private static final Integer INACTIVITY_DAYS = 90;

    public Iterable<Account> start(Database.BatchableContext bc) {

        // Find Accounts with no activity in the last X days
        Date cutoffDate = Date.today().addDays(-INACTIVITY_DAYS);

        // Get query from custom label
        String query = Label.AccountQueryIn_Apex_AccountFollowUpTaskBatch;

        // Replace placeholder with date value
        query = query.replace(
            '{0}',
            String.valueOf(cutoffDate)
        );

        System.debug('Query >>> ' + query);

        return (List<Account>) Database.query(query);
    }

    public void execute(
        Database.BatchableContext bc,
        List<Account> accounts
    ) {

        if (accounts == null || accounts.isEmpty()) {
            return;
        }

        List<Task> tasksToInsert = new List<Task>();

        for (Account acc : accounts) {

            // Skip inactive owners
            if (acc.OwnerId == null ||
                acc.Owner == null ||
                !acc.Owner.IsActive) {

                System.debug(
                    LoggingLevel.WARN,
                    'Skipping Account: ' + acc.Id +
                    ' because owner is inactive or missing.'
                );
        
                continue;
            }

            Boolean shouldCreateTask = false;
            List<Task> openTasks = acc.Tasks;

            if (openTasks != null && !openTasks.isEmpty()) {

                Task latestOpenTask = openTasks[0];
                DateTime nintyDaysAgo = System.now().addDays(-90);

                if (latestOpenTask.LastModifiedDate < nintyDaysAgo) {
                    shouldCreateTask = true;
                }

            } else {
                shouldCreateTask = true;
            }

            if (shouldCreateTask) {

                tasksToInsert.add(
                    new Task(
                        Subject = TASK_SUBJECT,
                        Status = TASK_STATUS,
                        Priority = TASK_PRIORITY,
                        OwnerId = acc.OwnerId,
                        WhatId = acc.Id
                    )
                );
            }
        }

        if (!tasksToInsert.isEmpty()) {

            // Will throw DML exception automatically if insert fails
            insert tasksToInsert;

            System.debug(
                LoggingLevel.INFO,
                'Successfully created ' +
                tasksToInsert.size() +
                ' follow-up task(s).'
            );
        }
    }

    public void finish(Database.BatchableContext bc) {

        System.debug(
            LoggingLevel.INFO,
            'AccountFollowUpTaskBatch finished.'
        );
    }
}