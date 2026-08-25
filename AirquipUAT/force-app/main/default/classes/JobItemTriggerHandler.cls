public class JobItemTriggerHandler {

    /**
     * Re-syncs conditional checklists for the given Jobs.
     * A "conditional" Checklist Item has fax__Is_Conditional__c = true and is tied
     * to both a Job Type and a Product. Checklists are only created when a
     * matching Job Item (same Product) exists on the Job.
     */
    public static void syncConditionalChecklists(Set<Id> affectedJobIds) {
        if (affectedJobIds == null || affectedJobIds.isEmpty()) return;

        Map<Id, fax__Job__c> jobMap = new Map<Id, fax__Job__c>([
            SELECT Id, fax__Job_Type__c
            FROM   fax__Job__c
            WHERE  Id IN :affectedJobIds
            AND    fax__Job_Type__c != null
        ]);
        if (jobMap.isEmpty()) return;

        Set<Id> jobTypeIds = new Set<Id>();
        for (fax__Job__c job : jobMap.values()) {
            jobTypeIds.add(job.fax__Job_Type__c);
        }

        // Remove stale conditional checklists on affected jobs so they can be re-created
        List<fax__Checklist__c> toDelete = [
            SELECT Id
            FROM   fax__Checklist__c
            WHERE  fax__Job__c IN :jobMap.keySet()
            AND    fax__Source_Item__r.fax__Job_Type__c IN :jobTypeIds
            AND    fax__Source_Item__r.fax__Is_Conditional__c = true
            AND    fax__Source_Item__r.Is_Job_Level_Checklist__c != 'Yes'
        ];
        if (!toDelete.isEmpty()) {
            delete toDelete;
        }

        // Gather current Products per Job from Job Items
        Map<Id, Set<Id>> jobToProducts = new Map<Id, Set<Id>>();
        for (Id jobId : jobMap.keySet()) {
            jobToProducts.put(jobId, new Set<Id>());
        }

        for (fax__Job_System__c item : [
            SELECT fax__Job_New__c, fax__Product__c
            FROM   fax__Job_System__c
            WHERE  fax__Job_New__c IN :jobMap.keySet()
            AND    fax__Product__c != null
        ]) {
            if (jobToProducts.containsKey(item.fax__Job_New__c)) {
                jobToProducts.get(item.fax__Job_New__c).add(item.fax__Product__c);
            }
        }

        Set<Id> allProductIds = new Set<Id>();
        for (Set<Id> pIds : jobToProducts.values()) {
            allProductIds.addAll(pIds);
        }
        if (allProductIds.isEmpty()) return;

        // Fetch matching conditional templates (Job Type + Product)
        List<fax__Checklist_Item__c> templates = [
            SELECT Id, fax__Job_Type__c, Product__c, fax__Item__c
            FROM   fax__Checklist_Item__c
            WHERE  fax__Job_Type__c IN :jobTypeIds
            AND    Product__c  IN :allProductIds
            AND    fax__Is_Conditional__c = true
        ];
        if (templates.isEmpty()) return;

        // Create conditional checklists
        List<fax__Checklist__c> newChecklists = new List<fax__Checklist__c>();
        for (Id jobId : jobMap.keySet()) {
            fax__Job__c job = jobMap.get(jobId);
            Set<Id> productIds = jobToProducts.get(jobId);
            if (productIds == null || productIds.isEmpty()) continue;

            for (fax__Checklist_Item__c tmpl : templates) {
                if (tmpl.fax__Job_Type__c == job.fax__Job_Type__c
                    && productIds.contains(tmpl.Product__c)) {
                    newChecklists.add(new fax__Checklist__c(
                        fax__Job__c        = jobId,
                        fax__Source_Item__c = tmpl.Id,
                        fax__Item__c       = tmpl.fax__Item__c
                    ));
                }
            }
        }

        if (!newChecklists.isEmpty()) insert newChecklists;
    }
}