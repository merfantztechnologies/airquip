public class AssignmentQuickActions {
    @AuraEnabled
    public static void UpdateGeolocation(Id assignmentId, String lon, String lat) {
        // Validate input
        if (assignmentId == null) {
            throw new AuraHandledException('Assignment Id is required.');
        }
        if (String.isBlank(lat) || String.isBlank(lon)) {
            throw new AuraHandledException('Latitude and Longitude are required.');
        }
        
        try {
            // 1) Query assignment to get Service Engineer
            fax__Assigned_Engineer__c assignmentRec = [
                SELECT Id, fax__Service_Engineer__c
                FROM fax__Assigned_Engineer__c
                WHERE Id = :assignmentId
                LIMIT 1
            ];
            
            Id engineerId = assignmentRec.fax__Service_Engineer__c;
            if (engineerId == null) {
                throw new AuraHandledException('No Service Engineer associated with this assignment.');
            }
            
            // 2) Query the Service Engineer record
            fax__Service_Engineer__c eng = [
                SELECT Id, fax__Latitude__c, fax__Longitude__c
                FROM fax__Service_Engineer__c
                WHERE Id = :engineerId
                LIMIT 1
            ];
            
            // 3) Update latitude & longitude
            eng.fax__Latitude__c = lat;
            eng.fax__Longitude__c = lon;
            update eng;
            
        } catch (Exception ex) {
            throw new AuraHandledException('UpdateGeolocation error: ' + ex.getMessage());
        }
    }
}