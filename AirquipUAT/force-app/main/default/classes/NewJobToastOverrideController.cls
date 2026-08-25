public class NewJobToastOverrideController {
    @AuraEnabled
    public static String getJobName(Id recordId) {
        fax__Job__c job = [SELECT Name FROM fax__Job__c WHERE Id = :recordId LIMIT 1];
        return job.Name;
    }
}