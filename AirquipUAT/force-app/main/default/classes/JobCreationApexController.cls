public with sharing class JobCreationApexController {
    public class OrderContactContext {
        @AuraEnabled public Id contactId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String contactName;
    }
    public class ContactWrapper {
        @AuraEnabled public String Id;
        @AuraEnabled public String Name;
        @AuraEnabled public String AccountName;
        /** Set when returning from create flows so UI can reload account contacts reliably */
        @AuraEnabled public String AccountId;
    }
    public class QuoteJobContext {
        @AuraEnabled public Id orderId;
        @AuraEnabled public Id existingJobId;
        @AuraEnabled public Id contactId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String contactName;
        @AuraEnabled public Boolean hasOrderProducts;
    }

    private static Boolean isOrderStatusValueAvailable(String valueToCheck) {
        for (Schema.PicklistEntry entry : Schema.SObjectType.Order.fields.Status.getPicklistValues()) {
            if (entry.isActive() && entry.getValue() == valueToCheck) {
                return true;
            }
        }
        return false;
    }

    @AuraEnabled
    public static List<fax__Job_Type__c> getJobTypes() {
        return [SELECT Id, Name FROM fax__Job_Type__c WHERE fax__Active__c = true ORDER BY Name ASC];
    }

    @AuraEnabled
    public static List<String> getPriorityOptions() {
        List<String> options = new List<String>();
        for (Schema.PicklistEntry entry : Schema.SObjectType.fax__Job__c.fields.fax__Urgency__c.getPicklistValues()) {
            if (entry.isActive()) options.add(entry.getValue());
        }
        return options;
    }

    @AuraEnabled
    public static List<String> getJobCategoryOptions() {
        List<String> options = new List<String>();
        for (Schema.PicklistEntry entry : Schema.SObjectType.fax__Job__c.fields.fax__Visit_Type__c.getPicklistValues()) {
            if (entry.isActive()) options.add(entry.getValue());
        }
        return options;
    }

    // NEW METHOD
    @AuraEnabled
    public static List<String> getStatusOptions() {
        List<String> options = new List<String>();
        for (Schema.PicklistEntry entry : Schema.SObjectType.fax__Job__c.fields.fax__Status__c.getPicklistValues()) {
            if (entry.isActive()) options.add(entry.getValue());
        }
        return options;
    }

    @AuraEnabled
    public static String checkExistingJob(String recId) {
        List<fax__Job__c> existingJobs = [
            SELECT Id FROM fax__Job__c
            WHERE Order__c = :recId
            AND fax__Status__c NOT IN ('Finalized', 'Cancelled', 'Completed')
            LIMIT 1
        ];
        return existingJobs.isEmpty() ? null : existingJobs[0].Id;
    }

    @AuraEnabled
    public static Boolean hasOrderProducts(String recId) {
        return [SELECT COUNT() FROM OrderItem WHERE OrderId = :recId] > 0;
    }

    @AuraEnabled
    public static OrderContactContext getOrderContactContext(String recId) {
        Order ord = [SELECT Id, AccountId, Contact__c, Contact__r.Name FROM Order WHERE Id = :recId LIMIT 1];
        OrderContactContext ctx = new OrderContactContext();
        ctx.contactId = ord.Contact__c;
        ctx.accountId = ord.AccountId;
        ctx.contactName = (ord.Contact__r != null) ? ord.Contact__r.Name : null;
        return ctx;
    }

    @AuraEnabled
    public static QuoteJobContext getQuoteJobContext(String quoteId) {
        if (String.isBlank(quoteId)) {
            throw new AuraHandledException('Quote Id is required.');
        }

        List<Order> orders = [
            SELECT Id, AccountId, Contact__c, Contact__r.Name
            FROM Order
            WHERE QuoteId = :quoteId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (orders.isEmpty()) {
            throw new AuraHandledException('No order was found for this approved quote.');
        }

        Order ord = orders[0];
        QuoteJobContext ctx = new QuoteJobContext();
        ctx.orderId = ord.Id;
        ctx.accountId = ord.AccountId;
        ctx.contactId = ord.Contact__c;
        ctx.contactName = ord.Contact__r != null ? ord.Contact__r.Name : null;
        ctx.hasOrderProducts = hasOrderProducts(ord.Id);

        String existingJobId = checkExistingJob(ord.Id);
        ctx.existingJobId = String.isBlank(existingJobId) ? null : (Id)existingJobId;

        return ctx;
    }

    @AuraEnabled
    public static ContactWrapper createContactForOrder(
        Id orderId,
        String firstName,
        String lastName,
        String email,
        String phone
    ) {
        try {
            if (orderId == null) {
                throw new AuraHandledException('Order Id is required.');
            }
            if (String.isBlank(email)) {
                throw new AuraHandledException('Email is required.');
            }
            if (String.isBlank(lastName)) {
                throw new AuraHandledException('Last Name is required.');
            }

            Order ord = [SELECT Id, AccountId FROM Order WHERE Id = :orderId LIMIT 1];

            if (ord.AccountId == null) {
                throw new AuraHandledException(
                    'This order does not have an Account. Assign an Account on the Order before creating a contact.'
                );
            }

            Contact c = new Contact();
            c.AccountId = ord.AccountId;
            c.Email = email.trim();
            c.LastName = lastName.trim();
            if (!String.isBlank(firstName)) {
                c.FirstName = firstName.trim();
            }
            if (!String.isBlank(phone)) {
                c.Phone = phone.trim();
            }

            insert c;

            Contact loaded = [
                SELECT Id, Name, AccountId, Account.Name
                FROM Contact
                WHERE Id = :c.Id
                LIMIT 1
            ];

            ContactWrapper w = new ContactWrapper();
            w.Id = loaded.Id;
            w.Name = loaded.Name;
            w.AccountId = loaded.AccountId != null ? String.valueOf(loaded.AccountId) : String.valueOf(ord.AccountId);
            w.AccountName = loaded.Account != null ? loaded.Account.Name : '';

            return w;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception ex) {
            throw new AuraHandledException('Error creating contact: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static List<ContactWrapper> getContactsByAccount(Id accountId) {

    List<ContactWrapper> results = new List<ContactWrapper>();

    for(Contact c : [
        SELECT Id, Name, Account.Name
        FROM Contact
        WHERE AccountId = :accountId
        ORDER BY LastModifiedDate DESC
    ]){

        ContactWrapper w = new ContactWrapper();
        w.Id = c.Id;
        w.Name = c.Name;
        w.AccountName = c.Account != null ? c.Account.Name : '';

        results.add(w);
    }

    return results;
    }

    @AuraEnabled
    public static Boolean hasAssignment(String jobId) {
        return [SELECT COUNT() FROM fax__Assigned_Engineer__c WHERE fax__Job_New__c = :jobId] > 0;
    }

    @AuraEnabled
    public static void completeOrder(String recId) {
        Order ord = [SELECT Id, Status FROM Order WHERE Id = :recId LIMIT 1];
        if (isOrderStatusValueAvailable('Completed')) {
            ord.Status = 'Completed';
            update ord;
        }
    }

    @AuraEnabled // UPDATED SIGNATURE
    public static String createJobFromRecord(String recId, String priority, String jobCategory, String selectedContactId, String status) {
        try {
            return createJobFromOrder(recId, priority, jobCategory, selectedContactId, System.now(), status);
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException('Error creating job: ' + ex.getMessage());
        }
    }

    @AuraEnabled // UPDATED SIGNATURE
    public static String createJobFromQuote(
        String quoteId,
        String priority,
        String jobCategory,
        String selectedContactId,
        String plannedVisitDateTime,
        String status // NEW
    ) {
        try {
            if (String.isBlank(quoteId)) {
                throw new AuraHandledException('Quote Id is required.');
            }

            List<Order> orders = [
                SELECT Id
                FROM Order
                WHERE QuoteId = :quoteId
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            if (orders.isEmpty()) {
                throw new AuraHandledException('No order was found for this approved quote.');
            }

            String existingJobId = checkExistingJob(orders[0].Id);
            if (!String.isBlank(existingJobId)) {
                return existingJobId;
            }

            return createJobFromOrder(
                orders[0].Id,
                priority,
                jobCategory,
                selectedContactId,
                parsePlannedVisitDateTime(plannedVisitDateTime),
                status // NEW
            );
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException('Error creating job: ' + ex.getMessage());
        }
    }

    private static DateTime parsePlannedVisitDateTime(String plannedVisitDateTime) {
        if (String.isBlank(plannedVisitDateTime)) {
            throw new AuraHandledException('Please select Planned Date');
        }

        String value = plannedVisitDateTime.trim();
        Boolean isGmt = value.endsWith('Z');
        value = value.replace('T', ' ').replace('Z', '');

        Integer decimalIndex = value.indexOf('.');
        if (decimalIndex > -1) {
            value = value.substring(0, decimalIndex);
        }
        if (value.length() == 16) {
            value += ':00';
        }

        return isGmt ? DateTime.valueOfGmt(value) : DateTime.valueOf(value);
    }

    // UPDATED SIGNATURE
    private static String createJobFromOrder(
        String recId,
        String priority,
        String jobCategory,
        String selectedContactId,    
        DateTime plannedVisitDateTime,
        String status // NEW
    ) {
        Order ord = [
            SELECT Id, AccountId, Contact__c, OpportunityId, QuoteId,
                   Case__c, Pricebook2Id, Status
            FROM Order WHERE Id = :recId LIMIT 1
        ];

        List<fax__Job__c> existingJobs = [
            SELECT Id FROM fax__Job__c
            WHERE Order__c = :recId
            AND fax__Status__c NOT IN ('Finalized', 'Cancelled', 'Completed')
            LIMIT 1
        ];
        if (!existingJobs.isEmpty()) return existingJobs[0].Id;

        if (String.isBlank(jobCategory)) {
            throw new AuraHandledException('Please select Job Category');
        }

        if (String.isBlank(priority)) {
            throw new AuraHandledException('Please select Priority');
        }

        if (String.isBlank(status)) { // NEW VALIDATION
            throw new AuraHandledException('Please select Status');
        }

        Id jobContactId = String.isNotBlank(selectedContactId)
            ? (Id) selectedContactId
            : ord.Contact__c;
        if (jobContactId == null) {
            throw new AuraHandledException('Please select Contact');
        }

        if (plannedVisitDateTime == null) {
            throw new AuraHandledException('Please select Planned Date');
        }

        List<OrderItem> orderItems = [
            SELECT Id, Product2Id, Quantity, UnitPrice, Line_Description__c
            FROM OrderItem WHERE OrderId = :ord.Id AND Product2Id != null
        ];
        if (orderItems.isEmpty()) {
            throw new AuraHandledException('Can\'t create Job without the order product');
        }

        fax__Job__c job = new fax__Job__c();
        job.fax__Customer__c                = ord.AccountId;
        job.fax__Contact__c                 = jobContactId;
        job.fax__Status__c                  = status; // REPLACED 'Queued' WITH DYNAMIC STATUS
        job.fax__Planned_Visit_Date_Time__c = plannedVisitDateTime;
        job.Order__c                        = ord.Id;
        job.fax__Source_Case__c             = ord.Case__c;
        job.Opportunity__c                  = ord.OpportunityId;
        job.Quote__c                        = ord.QuoteId;
        job.fax__PriceBook__c               = ord.Pricebook2Id;
        job.fax__Visit_Type__c              = jobCategory;
        job.fax__Urgency__c                 = priority;
        insert job;

        Set<Id> productIds = new Set<Id>();
        for (OrderItem oi : orderItems) productIds.add(oi.Product2Id);

        Map<Id, Decimal> productToPrice = new Map<Id, Decimal>();
        if (ord.Pricebook2Id != null && !productIds.isEmpty()) {
            for (PricebookEntry pbe : [
                SELECT Product2Id, UnitPrice FROM PricebookEntry
                WHERE Pricebook2Id = :ord.Pricebook2Id
                AND Product2Id IN :productIds AND IsActive = true
            ]) {
                productToPrice.put(pbe.Product2Id, pbe.UnitPrice);
            }
        }

        List<fax__Job_System__c> jobSystemsToInsert = new List<fax__Job_System__c>();
        for (OrderItem oi : orderItems) {
            Decimal unitPrice = productToPrice.containsKey(oi.Product2Id)
                ? productToPrice.get(oi.Product2Id) : oi.UnitPrice;
            jobSystemsToInsert.add(new fax__Job_System__c(
                fax__Job_New__c      = job.Id,
                fax__Product__c      = oi.Product2Id,
                fax__Quantity__c     = oi.Quantity,
                fax__Unit_Price__c   = unitPrice,
                Engineer_Comments__c = oi.Line_Description__c,
                Order_Item__c        = oi.Id
            ));
        }
        insert jobSystemsToInsert;

        ord.Job__c = job.Id;
        if (isOrderStatusValueAvailable('Activated')) {
            ord.Status = 'Activated';
        } else {
            throw new AuraHandledException('Order status value "Activated" is not configured.');
        }
        update ord;

        return job.Id;
    }
}