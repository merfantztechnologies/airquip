global class ServiceTermExpiryScheduler implements Schedulable {

    global void execute(SchedulableContext sc) {
        ServiceTermTriggerHandler.sendContractExpiryReminders();

    }
}