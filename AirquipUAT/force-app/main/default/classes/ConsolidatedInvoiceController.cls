public without sharing class ConsolidatedInvoiceController {
    private static final Set<String> ELIGIBLE_JOB_STATUSES = new Set<String>{
        'Completed',
        'Finalized'
    };
    private static final String INVOICE_STATUS_DRAFT = 'Draft';

    public class EligibleJob {
        @AuraEnabled public Id jobId { get; set; }
        @AuraEnabled public String jobNumber { get; set; }
        @AuraEnabled public String jobName { get; set; }
        @AuraEnabled public String jobCategory { get; set; }
        @AuraEnabled public String serviceEngineer { get; set; }
        @AuraEnabled public Datetime completionDate { get; set; }
        @AuraEnabled public String status { get; set; }

        public EligibleJob(fax__Job__c jobRecord) {
            jobId = jobRecord.Id;
            jobNumber = jobRecord.Name;
            jobName = jobRecord.fax__Job_Detail__c;
            jobCategory = jobRecord.fax__Visit_Type__c;
            serviceEngineer = jobRecord.Service_Engineer__r == null
                ? null
                : jobRecord.Service_Engineer__r.Name;
            completionDate = jobRecord.fax__Completion_Date_Time__c;
            status = jobRecord.fax__Status__c;
        }
    }

    public class GenerateInvoiceResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public Integer jobsAddedCount { get; set; }
        @AuraEnabled public Id invoiceId { get; set; }

        public GenerateInvoiceResult(Boolean success, String message, Integer jobsAddedCount, Id invoiceId) {
            this.success = success;
            this.message = message;
            this.jobsAddedCount = jobsAddedCount;
            this.invoiceId = invoiceId;
        }
    }

    @AuraEnabled
    public static List<EligibleJob> getEligibleJobs(Id accountId) {
        if (accountId == null) {
            throw new AuraHandledException('Account Id is required to load eligible jobs.');
        }

        try {
            queryAccount(accountId);

            List<fax__Job__c> completedJobs = queryCompletedJobsForAccount(accountId);
            if (completedJobs.isEmpty()) {
                return new List<EligibleJob>();
            }

            Set<Id> candidateJobIds = new Map<Id, fax__Job__c>(completedJobs).keySet();
            Map<Id, String> directInvoiceStatusByJobId = getDirectInvoiceStatusByJobId(candidateJobIds);
            Set<Id> jobsOnConsolidatedInvoice = getJobsOnConsolidatedInvoice(candidateJobIds);

            List<EligibleJob> eligibleJobs = new List<EligibleJob>();
            for (fax__Job__c jobRecord : completedJobs) {
                if (
                    !jobsOnConsolidatedInvoice.contains(jobRecord.Id) &&
                    isJobEligibleForConsolidation(jobRecord.Id, directInvoiceStatusByJobId)
                ) {
                    eligibleJobs.add(new EligibleJob(jobRecord));
                }
            }
            return eligibleJobs;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            logException('getEligibleJobs', ex);
            throw new AuraHandledException('Unable to load eligible jobs. Please try again or contact your administrator.');
        }
    }

    @AuraEnabled
    public static GenerateInvoiceResult generateConsolidatedInvoice(Id accountId, List<Id> jobIds) {
        if (accountId == null) {
            throw new AuraHandledException('Account Id is required.');
        }
        if (jobIds == null || jobIds.isEmpty()) {
            throw new AuraHandledException('Please select at least one job.');
        }

        Set<Id> selectedJobIds = new Set<Id>(jobIds);
        Savepoint savepoint = Database.setSavepoint();

        try {
            queryAccount(accountId);

            List<fax__Job__c> selectedJobs = [
                SELECT Id, Name, fax__Customer__c, fax__Status__c, fax__Contact__c, Invoice_Required__c
                FROM fax__Job__c
                WHERE Id IN :selectedJobIds
                FOR UPDATE
            ];

            if (selectedJobs.size() != selectedJobIds.size()) {
                throw new AuraHandledException('One or more selected jobs could not be found. Refresh the list and try again.');
            }

            validateSelectedJobs(accountId, selectedJobs, selectedJobIds);

            fax__Invoice__c invoiceRecord = createDraftInvoice(accountId, selectedJobs);
            insert invoiceRecord;

            List<Consolidated_Invoice_Job__c> junctionRecords = new List<Consolidated_Invoice_Job__c>();
            for (fax__Job__c jobRecord : selectedJobs) {
                junctionRecords.add(
                    new Consolidated_Invoice_Job__c(
                        Invoice__c = invoiceRecord.Id,
                        Account__c = accountId,
                        Job__c = jobRecord.Id,
                        Invoice_Job_Key__c = String.valueOf(invoiceRecord.Id) + '-' + String.valueOf(jobRecord.Id)
                    )
                );
            }

            insert junctionRecords;

            return new GenerateInvoiceResult(
                true,
                junctionRecords.size() + ' job(s) were added to the consolidated invoice successfully.',
                junctionRecords.size(),
                invoiceRecord.Id
            );
        } catch (AuraHandledException ex) {
            Database.rollback(savepoint);
            throw ex;
        } catch (DmlException ex) {
            Database.rollback(savepoint);
            logException('generateConsolidatedInvoice', ex);
            throw new AuraHandledException('Unable to generate the consolidated invoice: ' + ex.getDmlMessage(0));
        } catch (Exception ex) {
            Database.rollback(savepoint);
            logException('generateConsolidatedInvoice', ex);
            throw new AuraHandledException('Unable to generate the consolidated invoice. Please try again or contact your administrator.');
        }
    }

    private static Account queryAccount(Id accountId) {
        List<Account> accounts = [
            SELECT Id, Name
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        if (accounts.isEmpty()) {
            throw new AuraHandledException('Account could not be found. Refresh the page and try again.');
        }

        return accounts[0];
    }

    private static fax__Invoice__c createDraftInvoice(Id accountId, List<fax__Job__c> selectedJobs) {
        fax__Invoice__c invoiceRecord = new fax__Invoice__c(
            fax__Site__c = accountId,
            fax__Status__c = INVOICE_STATUS_DRAFT,
            fax__Date__c = Date.today(),
            fax__Due_Date__c = Date.today(),
            fax__Copy_Billing_Address_from_Site__c = true
        );

        for (fax__Job__c jobRecord : selectedJobs) {
            if (jobRecord.fax__Contact__c != null) {
                invoiceRecord.fax__Contact__c = jobRecord.fax__Contact__c;
                break;
            }
        }

        return invoiceRecord;
    }

    private static List<fax__Job__c> queryCompletedJobsForAccount(Id accountId) {
        return [
            SELECT Id,
                   Name,
                   fax__Job_Detail__c,
                   fax__Completion_Date_Time__c,
                   fax__Status__c,
                   fax__Visit_Type__c,
                   Invoice_Required__c,
                   Service_Engineer__r.Name
            FROM fax__Job__c
            WHERE fax__Customer__c = :accountId
            AND fax__Status__c IN :ELIGIBLE_JOB_STATUSES
            AND Invoice_Required__c = TRUE
            ORDER BY fax__Completion_Date_Time__c ASC NULLS LAST, Name ASC
        ];
    }

    private static Set<Id> getJobsOnConsolidatedInvoice(Set<Id> jobIds) {
        Set<Id> jobsOnConsolidatedInvoice = new Set<Id>();
        if (jobIds == null || jobIds.isEmpty()) {
            return jobsOnConsolidatedInvoice;
        }

        for (Consolidated_Invoice_Job__c junctionRecord : [
            SELECT Job__c
            FROM Consolidated_Invoice_Job__c
            WHERE Job__c IN :jobIds
            AND Job__c != NULL
        ]) {
            jobsOnConsolidatedInvoice.add(junctionRecord.Job__c);
        }

        return jobsOnConsolidatedInvoice;
    }

    private static Map<Id, String> getDirectInvoiceStatusByJobId(Set<Id> jobIds) {
        Map<Id, String> statusByJobId = new Map<Id, String>();
        if (jobIds == null || jobIds.isEmpty()) {
            return statusByJobId;
        }

        for (fax__Invoice__c invoiceRecord : [
            SELECT fax__Job__c, fax__Status__c
            FROM fax__Invoice__c
            WHERE fax__Job__c IN :jobIds
        ]) {
            statusByJobId.put(invoiceRecord.fax__Job__c, invoiceRecord.fax__Status__c);
        }

        return statusByJobId;
    }

    private static Boolean isJobEligibleForConsolidation(Id jobId, Map<Id, String> directInvoiceStatusByJobId) {
        if (!directInvoiceStatusByJobId.containsKey(jobId)) {
            return true;
        }

        return !ConsolidatedInvoiceJobService.isBlockingInvoiceStatus(directInvoiceStatusByJobId.get(jobId));
    }

    private static void validateSelectedJobs(
        Id accountId,
        List<fax__Job__c> selectedJobs,
        Set<Id> selectedJobIds
    ) {
        Map<Id, String> directInvoiceStatusByJobId = getDirectInvoiceStatusByJobId(selectedJobIds);
        Set<Id> jobsOnConsolidatedInvoice = getJobsOnConsolidatedInvoice(selectedJobIds);

        for (fax__Job__c jobRecord : selectedJobs) {
            if (jobRecord.fax__Customer__c != accountId) {
                throw new AuraHandledException('Selected jobs must belong to the selected account.');
            }
            if (!jobRecord.Invoice_Required__c) {
                throw new AuraHandledException('Only jobs that require an invoice can be added to a consolidated invoice.');
            }
            if (!ELIGIBLE_JOB_STATUSES.contains(jobRecord.fax__Status__c)) {
                throw new AuraHandledException('Only completed jobs can be added to a consolidated invoice.');
            }
            if (jobsOnConsolidatedInvoice.contains(jobRecord.Id)) {
                throw new AuraHandledException(
                    'One or more selected jobs are already on a consolidated invoice. Refresh the list and try again.'
                );
            }
            if (!isJobEligibleForConsolidation(jobRecord.Id, directInvoiceStatusByJobId)) {
                throw new AuraHandledException(
                    'One or more selected jobs are linked to an invoice that is no longer eligible. Refresh the list and try again.'
                );
            }
        }
    }

    private static void logException(String methodName, Exception ex) {
        System.debug(
            LoggingLevel.ERROR,
            'ConsolidatedInvoiceController.' + methodName + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString()
        );
    }
}