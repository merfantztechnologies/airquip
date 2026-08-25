public class TimeCardTriggerHandler {

    private static Boolean isRunning = false;

    public static void updateJobHours(
        List<fax__Time_Card__c> newList,
        List<fax__Time_Card__c> oldList,
        Boolean isInsert,
        Boolean isUpdate,
        Boolean isDelete,
        Boolean isUndelete
    ){

        if(isRunning) return;
        isRunning = true;

        Set<Id> jobIds = new Set<Id>();

        if(isInsert || isUpdate || isUndelete){
            for(fax__Time_Card__c tc : newList){
                if(tc.fax__Job2__c != null){
                    jobIds.add(tc.fax__Job2__c);
                }
            }
        }

        if(isDelete || isUpdate){
            for(fax__Time_Card__c tc : oldList){
                if(tc.fax__Job2__c != null){
                    jobIds.add(tc.fax__Job2__c);
                }
            }
        }

        if(jobIds.isEmpty()){
            isRunning = false;
            return;
        }

        /* ===============================
           AGGREGATE HOURS
        ===============================*/
        Map<Id, Decimal> laborMap = new Map<Id, Decimal>();
        Map<Id, Decimal> travelMap = new Map<Id, Decimal>();

        for(AggregateResult ar : [
            SELECT fax__Job2__c jobId,
                   fax__Time_for__c timeType,
                   SUM(fax__Hours__c) totalHours
            FROM fax__Time_Card__c
            WHERE fax__Job2__c IN :jobIds
            GROUP BY fax__Job2__c, fax__Time_for__c
        ]){
            Id jobId = (Id) ar.get('jobId');
            String type = (String) ar.get('timeType');
            Decimal total = (Decimal) ar.get('totalHours');

            if(type == 'Job'){
                laborMap.put(jobId, total);
            }
            else if(type == 'Travel'){
                travelMap.put(jobId, total);
            }
        }

        /* ===============================
           UPDATE JOB HOURS
        ===============================*/
        List<fax__Job__c> jobsToUpdate = new List<fax__Job__c>();

        for(fax__Job__c job : [
            SELECT Id, Labor_Time_Hrs__c, Travel_Time_Hrs__c
            FROM fax__Job__c
            WHERE Id IN :jobIds
        ]){

            Decimal labour = laborMap.containsKey(job.Id) ? laborMap.get(job.Id) : 0;
            Decimal travel = travelMap.containsKey(job.Id) ? travelMap.get(job.Id) : 0;

            if(job.Labor_Time_Hrs__c != labour ||
               job.Travel_Time_Hrs__c != travel){

                job.Labor_Time_Hrs__c = labour;
                job.Travel_Time_Hrs__c = travel;

                jobsToUpdate.add(job);
            }
        }

        if(!jobsToUpdate.isEmpty()){
            update jobsToUpdate;
        }


        isRunning = false;
    }
}