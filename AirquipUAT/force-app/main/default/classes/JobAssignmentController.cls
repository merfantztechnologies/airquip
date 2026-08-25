public without sharing class JobAssignmentController {

    /*private static final Set<String> TERMINAL_STATUSES = new Set<String>{
        'Rejected', 'Rescheduled', 'Completed'
    };
    private static final String TIME_TYPE_TRAVEL = 'Travel';
    private static final String TIME_TYPE_JOB = 'Job';
    public class AssignmentContext {
        @AuraEnabled public Boolean isVisible;
        @AuraEnabled public Integer assignmentCount;
        @AuraEnabled public AssignmentDetails assignment;
        @AuraEnabled public List<AssignmentSummary> allAssignments;
        @AuraEnabled public List<PicklistOption> statusOptions;
        @AuraEnabled public Boolean canEditOwnAssignment;
    }

    public class AssignmentSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String engineerName;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isOwnAssignment;
        @AuraEnabled public Boolean isEditable;
        @AuraEnabled public Datetime scheduledStart;
        @AuraEnabled public Datetime scheduledEnd;
    }

    public class AssignmentDetails {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String engineerName;
        @AuraEnabled public Date acceptedDate;
        @AuraEnabled public Datetime travelStart;
        @AuraEnabled public Datetime travelEnd;
        @AuraEnabled public Datetime startDateTime;
        @AuraEnabled public Datetime endDateTime;
        @AuraEnabled public Datetime plannedStart;
        @AuraEnabled public Datetime plannedEnd;
        @AuraEnabled public Boolean allDay;
        @AuraEnabled public String rejectionReason;
    }

    public class PicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    @AuraEnabled(cacheable=true)
    public static AssignmentContext getMyAssignmentContext(Id jobId) {
        try {
            return buildAssignmentContext(jobId);
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(toUserMessage(ex));
        }
    }

    private static AssignmentContext buildAssignmentContext(Id jobId) {
        AssignmentContext context = new AssignmentContext();
        context.isVisible = false;
        context.assignmentCount = 0;
        context.statusOptions = new List<PicklistOption>();

        if (jobId == null) {
            return context;
        }

        context.assignmentCount = [
            SELECT COUNT()
            FROM fax__Assigned_Engineer__c
            WHERE fax__Job_New__c = :jobId
        ];

        if (context.assignmentCount < 2) {
            return context;
        }

        List<fax__Assigned_Engineer__c> assignments = [
            SELECT Id, Name, fax__Status__c,
                   fax__Accepted_Date__c, fax__Travel_Start__c, fax__Travel_End__c,
                   fax__Start_Date_Time_cu__c, fax__End_Start_time_cus__c,
                   fax__Start__c, fax__End__c, fax__All_Day__c,
                   fax__Rejection_Reason__c,
                   fax__Service_Engineer__r.Name
            FROM fax__Assigned_Engineer__c
            WHERE fax__Job_New__c = :jobId
            AND fax__Service_Engineer__r.fax__Salesforce_user__c = :UserInfo.getUserId()
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (assignments.isEmpty()) {
            return context;
        }

        context.isVisible = true;
        context.assignment = mapToDetails(assignments[0]);
        context.canEditOwnAssignment = true;
        context.allAssignments = getAllAssignmentSummaries(jobId, assignments[0].Id);
        context.statusOptions = getStatusPicklistValues();
        return context;
    }

    @AuraEnabled
    public static AssignmentDetails updateMyAssignmentStatus(
        Id assignmentId,
        String newStatus,
        String latitude,
        String longitude
    ) {
        try {
            if (String.isBlank(newStatus)) {
                throw new AuraHandledException('Status is required.');
            }

            fax__Assigned_Engineer__c assignment = getOwnedAssignment(assignmentId, true);

            applyStatusTimestamps(assignment, newStatus);

            assignment.fax__Status__c = newStatus;
            update assignment;

            updateGeolocation(assignment.Id, latitude, longitude);
            createTimeCardsForStatusChange(assignment, newStatus);

            return getAssignmentDetails(assignment.Id);
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(toUserMessage(ex));
        }
    }

    @AuraEnabled
    public static AssignmentDetails updateMyAssignment(
        Id assignmentId,
        Datetime plannedStart,
        Datetime plannedEnd,
        Boolean allDay,
        String rejectionReason
    ) {
        try {
            fax__Assigned_Engineer__c assignment = getOwnedAssignment(assignmentId, true);
            assignment.fax__Start__c = plannedStart;
            assignment.fax__End__c = plannedEnd;
            assignment.fax__All_Day__c = allDay;
            assignment.fax__Rejection_Reason__c = rejectionReason;
            update assignment;
            return getAssignmentDetails(assignment.Id);
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(toUserMessage(ex));
        }
    }

    @TestVisible
    private static String toUserMessage(Exception ex) {
        if (ex instanceof DmlException) {
            DmlException dmlEx = (DmlException) ex;
            if (dmlEx.getNumDml() > 0 && String.isNotBlank(dmlEx.getDmlMessage(0))) {
                return stripFieldApiSuffix(dmlEx.getDmlMessage(0));
            }
        }

        String message = ex.getMessage();
        return String.isNotBlank(message) ? stripFieldApiSuffix(message) : 'An unexpected error occurred.';
    }

    private static String stripFieldApiSuffix(String message) {
        if (String.isBlank(message)) {
            return message;
        }

        Integer fieldSuffixIndex = message.lastIndexOf(': [');
        if (fieldSuffixIndex > -1 && message.endsWith(']')) {
            return message.substring(0, fieldSuffixIndex).trim();
        }

        return message.trim();
    }

    private static fax__Assigned_Engineer__c getOwnedAssignment(Id assignmentId, Boolean allowCompletedEdit) {
        if (assignmentId == null) {
            throw new AuraHandledException('Assignment Id is required.');
        }

        List<fax__Assigned_Engineer__c> assignments = [
            SELECT Id, fax__Status__c, fax__Job_New__c, fax__Service_Engineer__c,
                   fax__Travel_Start__c, fax__Travel_End__c,
                   fax__Start_Date_Time_cu__c, fax__End_Start_time_cus__c,
                   fax__Accepted_Date__c, fax__Start__c, fax__End__c,
                   fax__All_Day__c, fax__Rejection_Reason__c
            FROM fax__Assigned_Engineer__c
            WHERE Id = :assignmentId
            AND fax__Service_Engineer__r.fax__Salesforce_user__c = :UserInfo.getUserId()
            LIMIT 1
        ];

        if (assignments.isEmpty()) {
            throw new AuraHandledException('You can only update your own assignment.');
        }

        if (!allowCompletedEdit && isTerminalStatus(assignments[0].fax__Status__c)) {
            throw new AuraHandledException('Completed assignments cannot be updated.');
        }

        return assignments[0];
    }

    private static Boolean isTerminalStatus(String status) {
        return status != null && TERMINAL_STATUSES.contains(status);
    }

    private static void applyStatusTimestamps(fax__Assigned_Engineer__c assignment, String newStatus) {
        if (newStatus == 'Accepted') {
            assignment.fax__Accepted_Date__c = Date.today();
            assignment.fax__End_Start_time_cus__c = null;
        } else if (newStatus == 'En Route') {
            assignment.fax__Travel_Start__c = System.now();
            assignment.fax__Travel_End__c = null;
            assignment.fax__End_Start_time_cus__c = null;
        } else if (newStatus == 'On Site') {
            assignment.fax__Travel_End__c = System.now();
            assignment.fax__Start_Date_Time_cu__c = System.now();
            assignment.fax__End_Start_time_cus__c = null;
        } else if (newStatus == 'Completed') {
            if (assignment.fax__Start_Date_Time_cu__c == null) {
                assignment.fax__Start_Date_Time_cu__c = System.now();
            }
            Datetime endTime = System.now();
            if (endTime < assignment.fax__Start_Date_Time_cu__c) {
                endTime = assignment.fax__Start_Date_Time_cu__c;
            }
            assignment.fax__End_Start_time_cus__c = endTime;
        }
    }

    private static void updateGeolocation(Id assignmentId, String latitude, String longitude) {
        if (String.isBlank(latitude) || String.isBlank(longitude)) {
            return;
        }

        fax__Assigned_Engineer__c assignment = [
            SELECT Id,
                   fax__Service_Engineer__r.Id,
                   fax__Service_Engineer__r.fax__Active__c,
                   fax__Service_Engineer__r.fax__Enable_GPS_Tracking__c
            FROM fax__Assigned_Engineer__c
            WHERE Id = :assignmentId
            AND fax__Service_Engineer__r.fax__Salesforce_user__c = :UserInfo.getUserId()
            LIMIT 1
        ];

        if (assignment.fax__Service_Engineer__r == null) {
            return;
        }

        if (assignment.fax__Service_Engineer__r.fax__Active__c == 'Yes'
            && assignment.fax__Service_Engineer__r.fax__Enable_GPS_Tracking__c) {
            update new fax__Service_Engineer__c(
                Id = assignment.fax__Service_Engineer__r.Id,
                fax__Latitude__c = latitude,
                fax__Longitude__c = longitude
            );
        }
    }

    private static AssignmentDetails getAssignmentDetails(Id assignmentId) {
        fax__Assigned_Engineer__c assignment = [
            SELECT Id, Name, fax__Status__c,
                   fax__Accepted_Date__c, fax__Travel_Start__c, fax__Travel_End__c,
                   fax__Start_Date_Time_cu__c, fax__End_Start_time_cus__c,
                   fax__Start__c, fax__End__c, fax__All_Day__c,
                   fax__Rejection_Reason__c,
                   fax__Service_Engineer__r.Name
            FROM fax__Assigned_Engineer__c
            WHERE Id = :assignmentId
            LIMIT 1
        ];
        return mapToDetails(assignment);
    }

    private static List<AssignmentSummary> getAllAssignmentSummaries(Id jobId, Id ownAssignmentId) {
        List<AssignmentSummary> summaries = new List<AssignmentSummary>();
        for (fax__Assigned_Engineer__c assignment : [
            SELECT Id, Name, fax__Status__c, fax__Start__c, fax__End__c,
                   fax__Service_Engineer__r.Name
            FROM fax__Assigned_Engineer__c
            WHERE fax__Job_New__c = :jobId
            ORDER BY CreatedDate ASC
        ]) {
            AssignmentSummary summary = new AssignmentSummary();
            summary.id = assignment.Id;
            summary.name = assignment.Name;
            summary.engineerName = assignment.fax__Service_Engineer__r != null
                ? assignment.fax__Service_Engineer__r.Name
                : null;
            summary.status = assignment.fax__Status__c;
            summary.isOwnAssignment = assignment.Id == ownAssignmentId;
            summary.isEditable = summary.isOwnAssignment;
            summary.scheduledStart = assignment.fax__Start__c;
            summary.scheduledEnd = assignment.fax__End__c;
            summaries.add(summary);
        }
        return summaries;
    }

    private static AssignmentDetails mapToDetails(fax__Assigned_Engineer__c assignment) {
        AssignmentDetails details = new AssignmentDetails();
        details.id = assignment.Id;
        details.name = assignment.Name;
        details.status = assignment.fax__Status__c;
        details.engineerName = assignment.fax__Service_Engineer__r != null
            ? assignment.fax__Service_Engineer__r.Name
            : null;
        details.acceptedDate = assignment.fax__Accepted_Date__c;
        details.travelStart = assignment.fax__Travel_Start__c;
        details.travelEnd = assignment.fax__Travel_End__c;
        details.startDateTime = assignment.fax__Start_Date_Time_cu__c;
        details.endDateTime = assignment.fax__End_Start_time_cus__c;
        details.plannedStart = assignment.fax__Start__c;
        details.plannedEnd = assignment.fax__End__c;
        details.allDay = assignment.fax__All_Day__c;
        details.rejectionReason = assignment.fax__Rejection_Reason__c;
        return details;
    }

    private static List<PicklistOption> getStatusPicklistValues() {
        List<PicklistOption> options = new List<PicklistOption>();
        Schema.DescribeFieldResult fieldDescribe = fax__Assigned_Engineer__c.fax__Status__c.getDescribe();

        for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
            if (!entry.isActive() || entry.getValue() == 'Rejected' || entry.getValue() == 'Rescheduled') {
                continue;
            }
            PicklistOption option = new PicklistOption();
            option.label = entry.getLabel();
            option.value = entry.getValue();
            options.add(option);
        }
        return options;
    }

    /**
     * Simple time card flow (same idea as Job_Status_Alert status branching):
     * - En Route  → insert Travel card
     * - On Site   → close open Travel + insert Job card
     * - Completed → close open Job card(s)
    
    private static void createTimeCardsForStatusChange(
        fax__Assigned_Engineer__c assignment,
        String newStatus
    ) {
        if (assignment == null || assignment.Id == null || String.isBlank(newStatus)) {
            return;
        }

        if (assignment.fax__Job_New__c == null || assignment.fax__Service_Engineer__c == null) {
            return;
        }

        Id jobId = assignment.fax__Job_New__c;
        Id engineerId = assignment.fax__Service_Engineer__c;

        if (newStatus == 'En Route') {
            if (assignment.fax__Travel_Start__c != null) {
                insert new fax__Time_Card__c(
                    fax__Job2__c = jobId,
                    fax__Service_Engineer__c = engineerId,
                    fax__Time_for__c = TIME_TYPE_TRAVEL,
                    fax__Timer_Start__c = assignment.fax__Travel_Start__c,
                    fax__Timer_End__c = null,
                    fax__Date__c = assignment.fax__Travel_Start__c.date()
                );
            }
        } else if (newStatus == 'On Site') {
            fax__Time_Card__c travelCard = getOpenTimeCard(jobId, engineerId, TIME_TYPE_TRAVEL);
            if (travelCard != null && assignment.fax__Travel_End__c != null) {
                closeTimeCard(travelCard, assignment.fax__Travel_End__c);
            }
            if (assignment.fax__Start_Date_Time_cu__c != null) {
                insert new fax__Time_Card__c(
                    fax__Job2__c = jobId,
                    fax__Service_Engineer__c = engineerId,
                    fax__Time_for__c = TIME_TYPE_JOB,
                    fax__Timer_Start__c = assignment.fax__Start_Date_Time_cu__c,
                    fax__Timer_End__c = null,
                    fax__Date__c = assignment.fax__Start_Date_Time_cu__c.date()
                );
            }
        } else if (newStatus == 'Completed') {
            if (assignment.fax__End_Start_time_cus__c == null) {
                return;
            }
            for (fax__Time_Card__c jobCard : getOpenTimeCards(jobId, engineerId, TIME_TYPE_JOB)) {
                closeTimeCard(jobCard, assignment.fax__End_Start_time_cus__c);
            }
        }
    }

    private static fax__Time_Card__c getOpenTimeCard(Id jobId, Id engineerId, String timeFor) {
        List<fax__Time_Card__c> cards = getOpenTimeCards(jobId, engineerId, timeFor);
        return cards.isEmpty() ? null : cards[0];
    }

    private static List<fax__Time_Card__c> getOpenTimeCards(Id jobId, Id engineerId, String timeFor) {
        return [
            SELECT Id, fax__Timer_Start__c, fax__Timer_End__c
            FROM fax__Time_Card__c
            WHERE fax__Job2__c = :jobId
            AND fax__Service_Engineer__c = :engineerId
            AND fax__Time_for__c = :timeFor
            AND fax__Timer_End__c = null
            ORDER BY CreatedDate DESC
        ];
    }

    private static void closeTimeCard(fax__Time_Card__c card, Datetime timerEnd) {
        Datetime startTime = card.fax__Timer_Start__c != null ? card.fax__Timer_Start__c : timerEnd;
        if (timerEnd < startTime) {
            timerEnd = startTime;
        }
        card.fax__Timer_End__c = timerEnd;
        card.fax__Hours__c = calculateHours(startTime, timerEnd);
        card.fax__Date__c = startTime.date();
        update card;
    }

    @TestVisible
    private static Decimal calculateHours(Datetime timerStart, Datetime timerEnd) {
        Long milliseconds = timerEnd.getTime() - timerStart.getTime();
        return Decimal.valueOf(milliseconds).divide(Decimal.valueOf(1000 * 60 * 60), 2, RoundingMode.HALF_UP);
    } */
}