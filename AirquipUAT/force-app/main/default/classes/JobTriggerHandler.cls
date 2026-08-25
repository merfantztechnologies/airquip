public class JobTriggerHandler {

    // ════════════════════════════════════════════════════════════════════════
    // Sync job-level checklists when Job Type is set on insert or changes on update.
    // Conditional (product-based) checklists are delegated to JobItemTriggerHandler.
    // ════════════════════════════════════════════════════════════════════════
    public static void syncChecklistFromJobType(
        List<fax__Job__c> newList,
        Map<Id, fax__Job__c> oldMap
    ) {
        if (newList == null || newList.isEmpty()) return;

        Set<Id> jobIdsToProcess = new Set<Id>();
        Map<Id, Id> jobToJobType = new Map<Id, Id>();
        Boolean isInsert = (oldMap == null);

        for (fax__Job__c job : newList) {
            if (job.Id == null) continue;

            if (isInsert) {
                if (job.fax__Job_Type__c == null) continue;
                jobIdsToProcess.add(job.Id);
                jobToJobType.put(job.Id, job.fax__Job_Type__c);
                continue;
            }

            fax__Job__c oldJob = oldMap.get(job.Id);
            if (oldJob == null || job.fax__Job_Type__c == oldJob.fax__Job_Type__c) continue;

            jobIdsToProcess.add(job.Id);
            if (job.fax__Job_Type__c != null) {
                jobToJobType.put(job.Id, job.fax__Job_Type__c);
            }
        }
        if (jobIdsToProcess.isEmpty()) return;

        List<fax__Checklist__c> existing = [
            SELECT Id
            FROM   fax__Checklist__c
            WHERE  fax__Job__c IN :jobIdsToProcess
        ];
        if (!existing.isEmpty()) {
            delete existing;
        }

        if (!jobToJobType.isEmpty()) {
            insertJobLevelChecklists(jobToJobType);
        }

        JobItemTriggerHandler.syncConditionalChecklists(jobIdsToProcess);
    }

    private static void insertJobLevelChecklists(Map<Id, Id> jobToJobType) {
        Set<Id> jobTypeIds = new Set<Id>(jobToJobType.values());

        List<fax__Checklist_Item__c> templates = [
            SELECT Id, fax__Job_Type__c, fax__Item__c
            FROM   fax__Checklist_Item__c
            WHERE  fax__Job_Type__c IN :jobTypeIds
            AND    Is_Job_Level_Checklist__c = 'Yes'
            AND    Product__c = ''
        ];
        if (templates.isEmpty()) return;

        Map<Id, List<fax__Checklist_Item__c>> templatesByJobType =
            new Map<Id, List<fax__Checklist_Item__c>>();
        for (fax__Checklist_Item__c tmpl : templates) {
            List<fax__Checklist_Item__c> bucket = templatesByJobType.get(tmpl.fax__Job_Type__c);
            if (bucket == null) {
                bucket = new List<fax__Checklist_Item__c>();
                templatesByJobType.put(tmpl.fax__Job_Type__c, bucket);
            }
            bucket.add(tmpl);
        }

        List<fax__Checklist__c> newChecklists = new List<fax__Checklist__c>();
        for (Id jobId : jobToJobType.keySet()) {
            List<fax__Checklist_Item__c> typeTemplates =
                templatesByJobType.get(jobToJobType.get(jobId));
            if (typeTemplates == null) continue;

            for (fax__Checklist_Item__c tmpl : typeTemplates) {
                newChecklists.add(new fax__Checklist__c(
                    fax__Job__c         = jobId,
                    fax__Source_Item__c = tmpl.Id,
                    fax__Item__c        = tmpl.fax__Item__c
                ));
            }
        }

        if (!newChecklists.isEmpty()) {
            insert newChecklists;
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // EXISTING — Update Assignments Based on Job Status
    // ════════════════════════════════════════════════════════════════════════
    public static void updateAssignmentsBasedOnJobStatus(
    List<fax__Job__c> newList,
    Map<Id, fax__Job__c> oldMap
) {
    if (oldMap == null) return;

    Set<Id> cancelledJobIds = new Set<Id>();
    Set<Id> onHoldJobIds    = new Set<Id>();

    for (fax__Job__c job : newList) {
        fax__Job__c oldJob = oldMap.get(job.Id);

        if (oldJob != null && job.fax__Status__c != oldJob.fax__Status__c) {
            if (job.fax__Status__c == 'Cancelled') {
                cancelledJobIds.add(job.Id);
            } 
            else if (job.fax__Status__c == 'On Hold') {
                onHoldJobIds.add(job.Id);
            }
        }
    }

    // If nothing to process, exit early
    if (cancelledJobIds.isEmpty() && onHoldJobIds.isEmpty()) return;

    List<fax__Assigned_Engineer__c> toUpdate = [
        SELECT Id, fax__Status__c, fax__Job_new__c
        FROM fax__Assigned_Engineer__c
        WHERE fax__Job_new__c IN :cancelledJobIds
           OR fax__Job_new__c IN :onHoldJobIds
    ];

    for (fax__Assigned_Engineer__c a : toUpdate) {
        if (cancelledJobIds.contains(a.fax__Job_new__c)) {
            a.fax__Status__c = 'Rejected';
        } 
        else if (onHoldJobIds.contains(a.fax__Job_new__c)) {
            a.fax__Status__c = 'Rescheduled';
        }
    }

    if (!toUpdate.isEmpty()) {
        update toUpdate;
    }
}

    // ════════════════════════════════════════════════════════════════════════
    // SMS ROW 4 — Technician Assigned → SMS Customer
    // FIX: Re-query Job with fax__Customer__r.Name to get Account name
    // Template: SMSTemplateService.TECHNICIAN_ASSIGNED
    // Placeholders: {CustomerName} {EngineerName} {JobNo} {PlannedDate}
    // ════════════════════════════════════════════════════════════════════════
    public static void sendSMSTechnicianAssigned(
        List<fax__Job__c> newList,
        Map<Id, fax__Job__c> oldMap
    ) {
        // Step 1: Find eligible jobs where engineer just changed
        Set<Id> eligibleJobIds = new Set<Id>();
        for (fax__Job__c job : newList) {
            fax__Job__c oldJob = oldMap != null ? oldMap.get(job.Id) : null;
            Boolean techAssigned =
                String.isNotBlank(job.Service_Engineer_Name__c) &&
                (oldJob == null ||
                 job.Service_Engineer_Name__c != oldJob.Service_Engineer_Name__c);
            if (techAssigned && String.isNotBlank(job.Contact_Phone__c)) {
                eligibleJobIds.add(job.Id);
            }
        }
        if (eligibleJobIds.isEmpty()) return;

        // Step 2: Re-query with relationship field to get Account name
        Map<Id, fax__Job__c> jobsWithCustomer = new Map<Id, fax__Job__c>([
            SELECT Id, Name,
                   Contact_Phone__c,
                   Service_Engineer_Name__c,
                   fax__Planned_Visit_Date_Time__c,
                   fax__Customer__c,
                   fax__Customer__r.Name
            FROM   fax__Job__c
            WHERE  Id IN :eligibleJobIds
        ]);

        // Step 3: Send SMS
        for (Id jobId : eligibleJobIds) {
            fax__Job__c job = jobsWithCustomer.get(jobId);
            if (job == null) continue;

            String customerName = nvl(job.fax__Customer__r.Name);
            System.debug('[JobTriggerHandler] Row 4 CustomerName: ' + customerName);

            String msg = SMSTemplateService.build(
                SMSTemplateService.TECHNICIAN_ASSIGNED,
                new Map<String, String>{
                    'CustomerName' => customerName,
                    'EngineerName' => nvl(job.Service_Engineer_Name__c),
                    'JobNo'        => nvl(job.Name),
                    'PlannedDate'  => job.fax__Planned_Visit_Date_Time__c != null
                                      ? job.fax__Planned_Visit_Date_Time__c.format('MMM d, yyyy')
                                      : 'TBD'
                }
            );
            if (String.isNotBlank(msg))
                RingCentralSMSService.sendSMS(job.Contact_Phone__c, msg);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SMS ROW 10 — Job Completed → SMS Customer
    // FIX: Re-query Job with fax__Customer__r.Name to get Account name
    // Template: SMSTemplateService.JOB_COMPLETED
    // Placeholders: {CustomerName} {JobNo}
    // ════════════════════════════════════════════════════════════════════════
    public static void sendSMSJobCompleted(
        List<fax__Job__c> newList,
        Map<Id, fax__Job__c> oldMap
    ) {
        if (oldMap == null) return;

        // Step 1: Find jobs just completed
        Set<Id> completedJobIds = new Set<Id>();
        for (fax__Job__c job : newList) {
            fax__Job__c oldJob = oldMap.get(job.Id);
            Boolean justCompleted =
                job.fax__Status__c == 'Completed' &&
                (oldJob == null || oldJob.fax__Status__c != 'Completed');
            if (justCompleted && String.isNotBlank(job.Contact_Phone__c)) {
                completedJobIds.add(job.Id);
            }
        }
        if (completedJobIds.isEmpty()) return;

        // Step 2: Re-query with relationship field
        Map<Id, fax__Job__c> jobsWithCustomer = new Map<Id, fax__Job__c>([
            SELECT Id, Name,
                   Contact_Phone__c,
                   fax__Customer__c,
                   fax__Customer__r.Name
            FROM   fax__Job__c
            WHERE  Id IN :completedJobIds
        ]);

        // Step 3: Send SMS
        for (Id jobId : completedJobIds) {
            fax__Job__c job = jobsWithCustomer.get(jobId);
            if (job == null) continue;

            String customerName = nvl(job.fax__Customer__r.Name);
            System.debug('[JobTriggerHandler] Row 10 CustomerName: ' + customerName);

            String msg = SMSTemplateService.build(
                SMSTemplateService.JOB_COMPLETED,
                new Map<String, String>{
                    'CustomerName' => customerName,
                    'JobNo'        => nvl(job.Name)
                }
            );
            if (String.isNotBlank(msg))
                RingCentralSMSService.sendSMS(job.Contact_Phone__c, msg);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // SMS ROW 14 — Auto Job Created from Service Plan → SMS Customer
    // FIX: Re-query Job with fax__Customer__r.Name to get Account name
    // Fires on Job INSERT when fax__Service_Plan__c is populated
    // Template: SMSTemplateService.FREQUENCY_JOB_CREATED
    // Placeholders: {CustomerName} {JobNo} {PlanNo} {ServiceDate}
    // ════════════════════════════════════════════════════════════════════════
    public static void sendSMSFrequencyJobCreated(
        List<fax__Job__c> newList
    ) {
        // Step 1: Collect eligible jobs with Service Plan
        Set<Id> eligibleJobIds = new Set<Id>();
        Set<Id> planIds        = new Set<Id>();

        for (fax__Job__c job : newList) {
            if (job.fax__Service_Plan__c != null &&
                String.isNotBlank(job.Contact_Phone__c)) {
                eligibleJobIds.add(job.Id);
                planIds.add(job.fax__Service_Plan__c);
            }
        }
        if (eligibleJobIds.isEmpty()) return;

        // Step 2: Re-query Jobs with relationship field
        Map<Id, fax__Job__c> jobsWithCustomer = new Map<Id, fax__Job__c>([
            SELECT Id, Name,
                   Contact_Phone__c,
                   fax__Service_Plan__c,
                   fax__Planned_Visit_Date_Time__c,
                   fax__Customer__c,
                   fax__Customer__r.Name
            FROM   fax__Job__c
            WHERE  Id IN :eligibleJobIds
        ]);

        // Step 3: Query Service Plans for Plan No
        Map<Id, fax__Service_Term__c> planMap = new Map<Id, fax__Service_Term__c>([
            SELECT Id, Name
            FROM   fax__Service_Term__c
            WHERE  Id IN :planIds
        ]);

        // Step 4: Send SMS
        for (Id jobId : eligibleJobIds) {
            fax__Job__c job = jobsWithCustomer.get(jobId);
            if (job == null) continue;

            String customerName = nvl(job.fax__Customer__r.Name);
            System.debug('[JobTriggerHandler] Row 14 CustomerName: ' + customerName);

            fax__Service_Term__c plan = planMap.get(job.fax__Service_Plan__c);
            String planNo      = plan != null ? nvl(plan.Name) : '';
            String serviceDate = job.fax__Planned_Visit_Date_Time__c != null
                                 ? job.fax__Planned_Visit_Date_Time__c.format('MMM d, yyyy')
                                 : 'TBD';

            String msg = SMSTemplateService.build(
                SMSTemplateService.FREQUENCY_JOB_CREATED,
                new Map<String, String>{
                    'CustomerName' => customerName,
                    'JobNo'        => nvl(job.Name),
                    'PlanNo'       => planNo,
                    'ServiceDate'  => serviceDate
                }
            );
            if (String.isNotBlank(msg))
                RingCentralSMSService.sendSMS(job.Contact_Phone__c, msg);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // EXISTING — Update Assignment Status (AuraEnabled)
    // ════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static void updateAssignmentStatus(Id jobId, String newStatus) {
        List<fax__Assigned_Engineer__c> lst = [
            SELECT Id, fax__Status__c,
                   fax__Travel_Start__c, fax__Travel_End__c,
                   fax__Start_Date_Time_cu__c, fax__End_Start_time_cus__c
            FROM   fax__Assigned_Engineer__c
            WHERE  fax__Job_New__c = :jobId
            AND    fax__Service_Engineer__r.fax__Salesforce_user__c = :UserInfo.getUserId()
            ORDER BY CreatedDate DESC
            LIMIT  1
        ];
        if (lst.isEmpty()) throw new AuraHandledException('No assignment found');

        fax__Assigned_Engineer__c ass = lst[0];
        if (newStatus == 'Accepted') {
            ass.fax__Accepted_Date__c = Date.today();
        } else if (newStatus == 'En Route') {
            ass.fax__Travel_Start__c = System.now();
            ass.fax__Travel_End__c   = null;
        } else if (newStatus == 'On Site') {
            ass.fax__Travel_End__c          = System.now();
            ass.fax__Start_Date_Time_cu__c  = System.now();
        }
        ass.fax__Status__c = newStatus;
        update ass;
    }

    // ════════════════════════════════════════════════════════════════════════
    // EXISTING — Update Geolocation (AuraEnabled)
    // ════════════════════════════════════════════════════════════════════════
    @AuraEnabled
    public static void UpdateGeolocation(Id jobId, String lon, String lat) {
        fax__Assigned_Engineer__c assignment = [
            SELECT Id,
                   fax__Service_Engineer__r.Id,
                   fax__Service_Engineer__r.fax__Active__c,
                   fax__Service_Engineer__r.fax__Latitude__c,
                   fax__Service_Engineer__r.fax__Longitude__c,
                   fax__Service_Engineer__r.fax__Enable_GPS_Tracking__c
            FROM   fax__Assigned_Engineer__c
            WHERE  fax__Job_New__c = :jobId
            AND    fax__Service_Engineer__r.fax__Salesforce_user__c = :UserInfo.getUserId()
            ORDER BY CreatedDate DESC
            LIMIT  1
        ];
        if (assignment.fax__Service_Engineer__r == null) return;

        if (assignment.fax__Service_Engineer__r.fax__Active__c == 'Yes'
            && assignment.fax__Service_Engineer__r.fax__Enable_GPS_Tracking__c) {
            update new fax__Service_Engineer__c(
                Id                = assignment.fax__Service_Engineer__r.Id,
                fax__Latitude__c  = lat,
                fax__Longitude__c = lon
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // UTILITY
    // ════════════════════════════════════════════════════════════════════════
    private static String nvl(String val) {
        return String.isNotBlank(val) ? val : '';
    }
    
    public static void removeDefaultChecklist(Set<Id> jobIds) {
        if (jobIds == null || jobIds.isEmpty()) return;

        List<fax__Checklist__c> checklistList = [
            SELECT Id
            FROM   fax__Checklist__c
            WHERE  fax__Job__c IN :jobIds
            AND    fax__Source_Item__r.Is_Job_Level_Checklist__c = 'Yes'
            AND    fax__Source_Item__r.Product__c = null
        ];

        if (!checklistList.isEmpty()) {
            delete checklistList;
        }
    }
    
  public static void restoreDefaultChecklist(List<fax__Job__c> jobs) {

    if (jobs == null || jobs.isEmpty()) {
        return;
    }

    Set<Id> jobIds = new Set<Id>();
    Map<Id, Id> jobTypeMap = new Map<Id, Id>();

    for (fax__Job__c job : jobs) {
        jobIds.add(job.Id);
        jobTypeMap.put(job.Id, job.fax__Job_Type__c);
    }

    List<fax__Checklist__c> deletedChecklists = [
        SELECT Id,
               fax__Job__c,
               fax__Source_Item__r.fax__Job_Type__c
        FROM fax__Checklist__c
        WHERE fax__Job__c IN :jobIds
        AND fax__Source_Item__r.Is_Job_Level_Checklist__c = 'Yes'
        AND fax__Source_Item__r.Product__c = null
        AND IsDeleted = true
        ALL ROWS
    ];

    List<fax__Checklist__c> toUndelete = new List<fax__Checklist__c>();

    for (fax__Checklist__c chk : deletedChecklists) {

        Id jobTypeId = jobTypeMap.get(chk.fax__Job__c);

        if (chk.fax__Source_Item__r.fax__Job_Type__c == jobTypeId) {
            toUndelete.add(chk);
        }
    }

    if (!toUndelete.isEmpty()) {
        undelete toUndelete;
    }
}
    
    /*====================================================
   * Method Name : GenerateInvoice
   * Description : Generate Invoice for closed jobs
   * Arguments : Map<Id, Job__c>
   ====================================================*/

  private static Set<Id> var_IDs;

  public static void GenerateInvoice(Map<Id, fax__Job__c> ScheduleNewMap) {
    if (ScheduleNewMap == null || ScheduleNewMap.isEmpty()) {
      return;
    }

    try {
      fax__Setting__mdt setting = fax__Setting__mdt.getInstance('General');

      // Create invoice only when Auto Generate Invoice = false
      if (setting == null || setting.fax__Auto_Generate_Invoice__c) {
        return;
      }

      List<fax__Invoice__c> InvoiceList = new List<fax__Invoice__c>();
      var_IDs = ScheduleNewMap.keySet();

      // Existing invoice map
      Map<Id, fax__Invoice__c> existingInvoices = new Map<Id, fax__Invoice__c>();

      for (fax__Invoice__c inv : [
        SELECT Id, fax__Job__c
        FROM fax__Invoice__c
        WHERE fax__Job__c IN :var_IDs
      ]) {
        existingInvoices.put(inv.fax__Job__c, inv);
      }

      for (fax__Job__c job : QueryJobsByIds('var_IDs')) {
        // Create invoice only if Job is closed, Consolidated invoice is false,
        // and Invoice does not already exist
        if (
          job.fax__Closed__c &&
          !job.Consolidated_Invoice__c &&
          job.Invoice_Required__c &&
          !existingInvoices.containsKey(job.Id)
        ) {
          fax__Invoice__c INV = new fax__Invoice__c();

          INV.fax__Job__c = job.Id;
          INV.fax__Status__c = 'In Review';
          INV.fax__Due_Date__c = System.today();
          INV.fax__Site__c = job.fax__Customer__c;
          INV.fax__Date__c = System.today();

          if (job.fax__Estimate__c != null) {
            INV.fax__Shipping_Handling__c = (job.fax__Estimate__r.fax__Shipping_Handling__c ==
              null
              ? 0
              : job.fax__Estimate__r.fax__Shipping_Handling__c);
          }

          INV.fax__Copy_Billing_Address_from_Site__c = true;

          INV.fax__Contact__c = (job.Fax__Contact__c == null
            ? job.fax__Service_Plan__r.fax__Site_Contact__c
            : job.Fax__Contact__c);

          if (UserInfo.isMultiCurrencyOrganization()) {
            INV.put('CurrencyIsoCode', (String) job.get('CurrencyIsoCode'));
          }

          InvoiceList.add(INV);
        }
      }

      if (!InvoiceList.isEmpty()) {
        Database.SaveResult[] results = Database.insert(
          InvoiceList,
          false,
          AccessLevel.USER_MODE
        );

        Map<Id, Id> jobToInvoiceIdMap = new Map<Id, Id>();

        for (Integer i = 0; i < results.size(); i++) {
          if (results[i].isSuccess()) {
            fax__Invoice__c inv = InvoiceList[i];
            jobToInvoiceIdMap.put(inv.fax__Job__c, inv.Id);
          } else {
            String errorMsg = '';
            for (Database.Error err : results[i].getErrors()) {
              errorMsg += err.getMessage() + ' ';
            }

            Id jobId = InvoiceList[i].fax__Job__c;

            if (ScheduleNewMap.containsKey(jobId)) {
              ScheduleNewMap.get(jobId)
                .addError('Invoice creation failed : ' + errorMsg);
            }
          }
        }

        if (!jobToInvoiceIdMap.isEmpty()) {
          Set<Id> invoiceIds = new Set<Id>(jobToInvoiceIdMap.values());
          List<fax__Invoice_Line_Item__c> existingLines = [
            SELECT Id, fax__Invoice__c, fax__Product__c, fax__Qty__c, Description__c
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c IN :invoiceIds
            WITH USER_MODE
          ];

          Map<String, List<fax__Invoice_Line_Item__c>> existingLinesMap = new Map<String, List<fax__Invoice_Line_Item__c>>();
          for (fax__Invoice_Line_Item__c line : existingLines) {
            String key = line.fax__Invoice__c + '-' + line.fax__Product__c;
            if (!existingLinesMap.containsKey(key)) {
              existingLinesMap.put(key, new List<fax__Invoice_Line_Item__c>());
            }
            existingLinesMap.get(key).add(line);
          }

          Set<Id> jobIds = jobToInvoiceIdMap.keySet();
          String query = 'SELECT Id, fax__Job_New__c, fax__Product__c, fax__Product__r.Description, fax__Quantity__c, fax__Unit_Price__c, Engineer_Comments__c';
          if (UserInfo.isMultiCurrencyOrganization()) {
            query += ', CurrencyIsoCode';
          }
          query += ' FROM fax__Job_System__c WHERE fax__Job_New__c IN :jobIds';

          List<fax__Job_System__c> jobSystems = (List<fax__Job_System__c>) Database.query(query, AccessLevel.USER_MODE);

          List<fax__Invoice_Line_Item__c> linesToInsert = new List<fax__Invoice_Line_Item__c>();
          List<fax__Invoice_Line_Item__c> linesToUpdate = new List<fax__Invoice_Line_Item__c>();

          for (fax__Job_System__c js : jobSystems) {
            Id invoiceId = jobToInvoiceIdMap.get(js.fax__Job_New__c);
            if (invoiceId == null) {
              continue;
            }

            String key = invoiceId + '-' + js.fax__Product__c;
            fax__Invoice_Line_Item__c matchedLine = null;

            if (existingLinesMap.containsKey(key)) {
              List<fax__Invoice_Line_Item__c> candidates = existingLinesMap.get(key);
              for (Integer idx = 0; idx < candidates.size(); idx++) {
                if (candidates[idx].fax__Qty__c == js.fax__Quantity__c) {
                  matchedLine = candidates.remove(idx);
                  break;
                }
              }
              if (matchedLine == null && !candidates.isEmpty()) {
                matchedLine = candidates.remove(0);
              }
            }

            String targetDesc = String.isNotBlank(js.Engineer_Comments__c)
              ? js.Engineer_Comments__c
              : js.fax__Product__r.Description;

            if (matchedLine != null) {
              fax__Invoice_Line_Item__c lineToUpdate = new fax__Invoice_Line_Item__c(
                Id = matchedLine.Id
              );
              Boolean needsUpdate = false;
              if (matchedLine.Description__c != targetDesc) {
                lineToUpdate.Description__c = targetDesc;
                needsUpdate = true;
              }
              if (needsUpdate) {
                linesToUpdate.add(lineToUpdate);
              }
            } else {
              fax__Invoice_Line_Item__c line = new fax__Invoice_Line_Item__c(
                fax__Invoice__c = invoiceId,
                fax__Product__c = js.fax__Product__c,
                fax__Qty__c = js.fax__Quantity__c,
                fax__Unit_Price__c = js.fax__Unit_Price__c,
                Description__c = targetDesc
              );
              if (UserInfo.isMultiCurrencyOrganization()) {
                line.put('CurrencyIsoCode', (String) js.get('CurrencyIsoCode'));
              }
              linesToInsert.add(line);
            }
          }

          if (!linesToUpdate.isEmpty()) {
            Database.SaveResult[] updateResults = Database.update(linesToUpdate, false, AccessLevel.USER_MODE);
            for (Database.SaveResult sr : updateResults) {
              if (!sr.isSuccess()) {
                System.debug('DEBUG_UPDATE_ERROR: ' + sr.getErrors()[0].getMessage());
              }
            }
          }
          if (!linesToInsert.isEmpty()) {
            Database.SaveResult[] insertResults = Database.insert(linesToInsert, false, AccessLevel.USER_MODE);
            for (Database.SaveResult sr : insertResults) {
              if (!sr.isSuccess()) {
                System.debug('DEBUG_INSERT_ERROR: ' + sr.getErrors()[0].getMessage());
              }
            }
          }
        }
      }
    } catch (Exception e) {
      for (fax__Job__c job : ScheduleNewMap.values()) {
        job.addError('Invoice creation failed : ' + e.getMessage());
      }
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  // Complete a sole assignment; validate multiple assignments before Job completion
  // ════════════════════════════════════════════════════════════════════════
  public static void validateAssignmentsBeforeCompletion(
    List<fax__Job__c> newList,
    Map<Id, fax__Job__c> oldMap
  ) {
    Set<Id> jobIdsToCheck = new Set<Id>();
    for (fax__Job__c job : newList) {
      fax__Job__c oldJob = oldMap != null ? oldMap.get(job.Id) : null;
      if (
        job.fax__Status__c == 'Completed' &&
        (oldJob == null ||
        oldJob.fax__Status__c != 'Completed')
      ) {
        jobIdsToCheck.add(job.Id);
      }
    }

    if (jobIdsToCheck.isEmpty()) {
      return;
    }

    List<fax__Assigned_Engineer__c> assignments = [
      SELECT Id, fax__Job_new__c, fax__Status__c
      FROM fax__Assigned_Engineer__c
      WHERE fax__Job_new__c IN :jobIdsToCheck
    ];

    Map<Id, List<fax__Assigned_Engineer__c>> jobToAssignments = new Map<Id, List<fax__Assigned_Engineer__c>>();
    for (fax__Assigned_Engineer__c assignment : assignments) {
      if (!jobToAssignments.containsKey(assignment.fax__Job_new__c)) {
        jobToAssignments.put(
          assignment.fax__Job_new__c,
          new List<fax__Assigned_Engineer__c>()
        );
      }
      jobToAssignments.get(assignment.fax__Job_new__c).add(assignment);
    }

    //List<fax__Assigned_Engineer__c> singleAssignmentsToComplete = new List<fax__Assigned_Engineer__c>();
    Map<Id, List<fax__Assigned_Engineer__c>> jobToIncompleteAssignments = new Map<Id, List<fax__Assigned_Engineer__c>>();

    for (Id jobId : jobToAssignments.keySet()) {
      List<fax__Assigned_Engineer__c> jobAssignments = jobToAssignments.get(
        jobId
      );

      /*if (jobAssignments.size() == 1) {
        fax__Assigned_Engineer__c assignment = jobAssignments[0];
        if (assignment.fax__Status__c != 'Completed') {
          assignment.fax__Status__c = 'Completed';
          singleAssignmentsToComplete.add(assignment);
        }
        continue;
      }*/

      for (fax__Assigned_Engineer__c assignment : jobAssignments) {
        if (
          assignment.fax__Status__c == 'Completed' ||
          assignment.fax__Status__c == 'Rejected' ||
          assignment.fax__Status__c == 'Rescheduled'
        ) {
          continue;
        }

        if (!jobToIncompleteAssignments.containsKey(jobId)) {
          jobToIncompleteAssignments.put(
            jobId,
            new List<fax__Assigned_Engineer__c>()
          );
        }
        jobToIncompleteAssignments.get(jobId).add(assignment);
      }
    }

    /*if (!singleAssignmentsToComplete.isEmpty()) {
      update singleAssignmentsToComplete;
    }*/

    for (fax__Job__c job : newList) {
      if (jobToIncompleteAssignments.containsKey(job.Id)) {
        job.addError(
          'Please complete the assignments before completing the job.'
        );
      }
    }
  }

  private static list<fax__Job__c> QueryJobsByIds(string Keyset) {
    string query = 'Select Id,fax__Customer__c,fax__Status__c,fax__Contact__c,fax__Estimate__c,fax__Estimate__r.fax__Shipping_Handling__c,fax__Service_Plan__r.fax__Site_Contact__c,fax__Next_Job__c,Invoice_Required__c,Consolidated_Invoice__c,';
    if (UserInfo.isMultiCurrencyOrganization())
      query += 'CurrencyIsoCode,';
    query += 'fax__Closed__c From fax__Job__c Where Id IN:' + Keyset;
    system.debug('------' + query);
    return (list<fax__Job__c>) Database.query(query, AccessLevel.USER_MODE);
  }

}