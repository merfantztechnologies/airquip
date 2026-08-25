public class ChecklistTriggerHandler {

    public static void syncJobChecklistCompleted(
        List<fax__Checklist__c> newList,
        Map<Id, fax__Checklist__c> oldMap
    ) {
        Set<Id> affectedJobIds = collectAffectedJobIds(newList, oldMap);
        syncJobChecklistCompleted(affectedJobIds);
    }

    public static void syncJobChecklistCompleted(Set<Id> jobIds) {
        if (jobIds == null || jobIds.isEmpty()) return;

        Set<Id> jobsWithIncompleteRequiredItems = new Set<Id>();

        for (fax__Checklist__c checklist : [
            SELECT fax__Job__c, fax__Notes__c
            FROM fax__Checklist__c
            WHERE fax__Job__c IN :jobIds
            AND Required__c = true
        ]) {
            if (String.isBlank(checklist.fax__Notes__c)) {
                jobsWithIncompleteRequiredItems.add(checklist.fax__Job__c);
            }
        }

        List<fax__Job__c> jobsToUpdate = new List<fax__Job__c>();
        for (fax__Job__c job : [
            SELECT Id, Checklist_Completed__c
            FROM fax__Job__c
            WHERE Id IN :jobIds
        ]) {
            Boolean shouldBeCompleted = !jobsWithIncompleteRequiredItems.contains(job.Id);

            if (job.Checklist_Completed__c != shouldBeCompleted) {
                jobsToUpdate.add(new fax__Job__c(
                    Id = job.Id,
                    Checklist_Completed__c = shouldBeCompleted
                ));
            }
        }

        if (!jobsToUpdate.isEmpty()) {
            update jobsToUpdate;
        }
    }

    private static Set<Id> collectAffectedJobIds(
        List<fax__Checklist__c> newList,
        Map<Id, fax__Checklist__c> oldMap
    ) {
        Set<Id> jobIds = new Set<Id>();

        if (newList != null) {
            for (fax__Checklist__c checklist : newList) {
                addJobId(jobIds, checklist);

                if (oldMap != null && oldMap.containsKey(checklist.Id)) {
                    addJobId(jobIds, oldMap.get(checklist.Id));
                }
            }
        }

        if (oldMap != null) {
            for (fax__Checklist__c checklist : oldMap.values()) {
                addJobId(jobIds, checklist);
            }
        }

        return jobIds;
    }

    private static void addJobId(Set<Id> jobIds, fax__Checklist__c checklist) {
        if (checklist != null && checklist.fax__Job__c != null) {
            jobIds.add(checklist.fax__Job__c);
        }
    }
}