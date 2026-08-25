public with sharing class OrderInvoiceService {
    private static final Set<String> ELIGIBLE_ORDER_STATUSES = new Set<String>{ 'Approved', 'Ready for Invoice' };
    private static final String DRAFT_INVOICE_STATUS = 'Draft';
    private static final Integer PRODUCT_SEARCH_LIMIT = 50;

    public class Workspace {
        @AuraEnabled public Boolean eligible;
        @AuraEnabled public String eligibilityMessage;
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String orderStatus;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id contactId;
        @AuraEnabled public Id ownerId;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String poNumber;
        @AuraEnabled public String terms;
        @AuraEnabled public String jobCategory;
        @AuraEnabled public Date transactionDate;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public String billingStreet;
        @AuraEnabled public String billingCity;
        @AuraEnabled public String billingState;
        @AuraEnabled public String billingPostalCode;
        @AuraEnabled public String siteStreet;
        @AuraEnabled public String siteCity;
        @AuraEnabled public String siteState;
        @AuraEnabled public String sitePostalCode;
        @AuraEnabled public Decimal subtotal;
        @AuraEnabled public Decimal tax;
        @AuraEnabled public Decimal grandTotal;
        @AuraEnabled public Decimal paymentReceived;
        @AuraEnabled public Decimal amountDue;
        @AuraEnabled public Boolean syncToQuickBooks;
        @AuraEnabled public Boolean sendToQuickBooks;
        @AuraEnabled public String quickBooksInvoiceId;
        @AuraEnabled public List<LineItem> lines;
    }

   public class LineItem {
    @AuraEnabled public String key { get; set; }
    @AuraEnabled public Id orderItemId { get; set; }
    @AuraEnabled public Id productId { get; set; }
    @AuraEnabled public String productName { get; set; }
    @AuraEnabled public String productCode { get; set; }
    @AuraEnabled public String description { get; set; }
    @AuraEnabled public Decimal quantity { get; set; }
    @AuraEnabled public Decimal unitPrice { get; set; }
    @AuraEnabled public Decimal cost { get; set; }
    @AuraEnabled public Boolean taxable { get; set; }
    @AuraEnabled public Decimal taxAmount { get; set; }
    @AuraEnabled public Decimal total { get; set; }
    @AuraEnabled public Boolean includeInInvoice { get; set; }
    @AuraEnabled public Boolean isDeleted { get; set; }
}

    public class ProductOption {
        @AuraEnabled public Id pricebookEntryId;
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal cost;
        @AuraEnabled public Boolean taxable;
    }

    public class SaveRequest {
    @AuraEnabled public Id orderId { get; set; }
    @AuraEnabled public Id accountId { get; set; }
    @AuraEnabled public Id contactId { get; set; }
    @AuraEnabled public Id ownerId { get; set; }
    @AuraEnabled public Date transactionDate { get; set; }
    @AuraEnabled public Date dueDate { get; set; }
    @AuraEnabled public String status { get; set; }
    @AuraEnabled public String classValue { get; set; }
    @AuraEnabled public String terms { get; set; }
    @AuraEnabled public String jobCategory { get; set; }
    @AuraEnabled public String poNumber { get; set; }
    @AuraEnabled public String jobDescription { get; set; }
    @AuraEnabled public String jobDetail { get; set; }
    @AuraEnabled public String engineerCompletionNotes { get; set; }
    @AuraEnabled public String billingStreet { get; set; }
    @AuraEnabled public String billingCity { get; set; }
    @AuraEnabled public String billingState { get; set; }
    @AuraEnabled public String billingPostalCode { get; set; }
    @AuraEnabled public Boolean syncToQuickBooks { get; set; }
    @AuraEnabled public Boolean sendToQuickBooks { get; set; }
    @AuraEnabled public String quickBooksInvoiceId { get; set; }
    @AuraEnabled public List<LineItem> lines { get; set; }
}

    public class SaveResult {
        @AuraEnabled public Id invoiceId;
    }

    public static Workspace getWorkspace(Id orderId) {
        if (orderId == null) {
            throw new AuraHandledException('Record Id is required.');
        }

        if (orderId.getSObjectType() == Order.SObjectType) {
            String orderSelect =
                'Id, OrderNumber, Status, AccountId, Account.Name, Account.BillingStreet,' +
                ' Account.BillingCity, Account.BillingState, Account.BillingPostalCode,' +
                ' Contact__c, OwnerId,' +
                ' Owner.Name, PoNumber, Payment_Terms__c, BillingStreet, BillingCity,' +
                ' BillingState, BillingPostalCode';
            if (fieldExists(Order.SObjectType, 'Job_Category__c')) {
                orderSelect += ', Job_Category__c';
            }
            Order ord = Database.query(
                'SELECT ' + orderSelect + ' FROM Order WHERE Id = :orderId LIMIT 1'
            );

            Workspace workspace = new Workspace();
            workspace.orderId = ord.Id;
            workspace.orderNumber = ord.OrderNumber;
            workspace.orderStatus = ord.Status;
            workspace.accountId = ord.AccountId;
            workspace.accountName = ord.Account != null ? ord.Account.Name : null;
            workspace.contactId = ord.Contact__c;
            workspace.ownerId = ord.OwnerId;
            workspace.ownerName = ord.Owner != null ? ord.Owner.Name : null;
            workspace.poNumber = ord.PoNumber;
            workspace.terms = (String) ord.get('Payment_Terms__c');
            if (fieldExists(Order.SObjectType, 'Job_Category__c')) {
                workspace.jobCategory = (String) ord.get('Job_Category__c');
            }
            workspace.transactionDate = Date.today();
            workspace.dueDate = calculateDueDate(workspace.transactionDate, workspace.terms);
            workspace.billingStreet = ord.BillingStreet;
            workspace.billingCity = ord.BillingCity;
            workspace.billingState = ord.BillingState;
            workspace.billingPostalCode = ord.BillingPostalCode;
            workspace.siteStreet = ord.Account != null ? ord.Account.BillingStreet : null;
            workspace.siteCity = ord.Account != null ? ord.Account.BillingCity : null;
            workspace.siteState = ord.Account != null ? ord.Account.BillingState : null;
            workspace.sitePostalCode = ord.Account != null ? ord.Account.BillingPostalCode : null;
            workspace.syncToQuickBooks = false;
            workspace.sendToQuickBooks = false;
            workspace.lines = buildLines(orderId);
            recalculateWorkspaceTotals(workspace);
            setEligibility(workspace);
            return workspace;
        } else if (orderId.getSObjectType() == Account.SObjectType) {
            Account acc = [
                SELECT Id, Name, Terms__c, BillingStreet, BillingCity, BillingState, BillingPostalCode, OwnerId, Owner.Name
                FROM Account
                WHERE Id = :orderId
                LIMIT 1
            ];

            Workspace workspace = new Workspace();
            workspace.orderId = null;
            workspace.orderNumber = null;
            workspace.orderStatus = null;
            workspace.accountId = acc.Id;
            workspace.accountName = acc.Name;
            
            List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id LIMIT 1];
            workspace.contactId = contacts.isEmpty() ? null : contacts[0].Id;
            
            workspace.ownerId = acc.OwnerId;
            workspace.ownerName = acc.Owner != null ? acc.Owner.Name : null;
            workspace.poNumber = null;
            workspace.terms = acc.Terms__c;
            workspace.jobCategory = null;
            workspace.transactionDate = Date.today();
            workspace.dueDate = calculateDueDate(workspace.transactionDate, workspace.terms);
            workspace.billingStreet = acc.BillingStreet;
            workspace.billingCity = acc.BillingCity;
            workspace.billingState = acc.BillingState;
            workspace.billingPostalCode = acc.BillingPostalCode;
            workspace.siteStreet = acc.BillingStreet;
            workspace.siteCity = acc.BillingCity;
            workspace.siteState = acc.BillingState;
            workspace.sitePostalCode = acc.BillingPostalCode;
            workspace.syncToQuickBooks = false;
            workspace.sendToQuickBooks = false;
            workspace.lines = new List<LineItem>();
            recalculateWorkspaceTotals(workspace);
            setAccountEligibility(workspace);
            return workspace;
        } else {
            throw new AuraHandledException('Unsupported record type.');
        }
    }

    private static void setAccountEligibility(Workspace workspace) {
        List<String> reasons = new List<String>();
        if (!Schema.sObjectType.fax__Invoice__c.isCreateable()) {
            reasons.add('You do not have permission to create invoices.');
        }
        if (!Schema.sObjectType.fax__Invoice_Line_Item__c.isCreateable()) {
            reasons.add('You do not have permission to create invoice lines.');
        }
        if (workspace.accountId == null) {
            reasons.add('Account is required.');
        }
        workspace.eligible = reasons.isEmpty();
        workspace.eligibilityMessage = String.join(reasons, ' ');
    }

    public static List<ProductOption> searchStandardProducts(String searchTerm) {
        try {
            Id standardPricebookId = getStandardActivePricebookId();
            Boolean pbeHasCost = fieldExists(PricebookEntry.SObjectType, 'Cost__c');

            String selectFields =
                'Id, UnitPrice, Product2Id, Product2.Name, Product2.ProductCode, Product2.Description, Product2.Is_Taxable__c';
            if (pbeHasCost) {
                selectFields += ', Cost__c';
            }

            List<ProductOption> options = new List<ProductOption>();

            if (String.isBlank(searchTerm)) {
                String soql =
                    'SELECT ' +
                    selectFields +
                    ' FROM PricebookEntry WHERE Pricebook2Id = :standardPricebookId' +
                    ' AND IsActive = TRUE AND Product2.IsActive = TRUE' +
                    ' AND (Product2.Is_Installed_System__c = false OR Product2.Is_Installed_System__c = NULL)' +
                    ' ORDER BY Product2.Name LIMIT :PRODUCT_SEARCH_LIMIT';
                for (PricebookEntry pbe : Database.query(soql)) {
                    options.add(mapPricebookEntryToProductOption(pbe, pbeHasCost));
                }
                return options;
            }

            String likeStr = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            Set<Id> matchedEntryIds = new Set<Id>();

            String nameCodeSoql =
                'SELECT ' +
                selectFields +
                ' FROM PricebookEntry WHERE Pricebook2Id = :standardPricebookId' +
                ' AND IsActive = TRUE AND Product2.IsActive = TRUE' +
                ' AND (Product2.Is_Installed_System__c = false OR Product2.Is_Installed_System__c = NULL)' +
                ' AND (Product2.Name LIKE :likeStr OR Product2.ProductCode LIKE :likeStr)' +
                ' ORDER BY Product2.Name LIMIT :PRODUCT_SEARCH_LIMIT';

            for (PricebookEntry pbe : Database.query(nameCodeSoql)) {
                matchedEntryIds.add(pbe.Id);
                options.add(mapPricebookEntryToProductOption(pbe, pbeHasCost));
            }

            Integer remainingLimit = PRODUCT_SEARCH_LIMIT - options.size();
            if (remainingLimit > 0) {
                String descriptionSoql =
                    'SELECT ' +
                    selectFields +
                    ' FROM PricebookEntry WHERE Pricebook2Id = :standardPricebookId' +
                    ' AND IsActive = TRUE AND Product2.IsActive = TRUE' +
                    ' AND (Product2.Is_Installed_System__c = false OR Product2.Is_Installed_System__c = NULL)' +
                    ' AND Product2.Description LIKE :likeStr AND Id NOT IN :matchedEntryIds' +
                    ' ORDER BY Product2.Name LIMIT :remainingLimit';
                for (PricebookEntry pbe : Database.query(descriptionSoql)) {
                    options.add(mapPricebookEntryToProductOption(pbe, pbeHasCost));
                }
            }

            return options;
        } catch (AuraHandledException handled) {
            throw handled;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OrderInvoiceService.searchStandardProducts failed: ' + e.getMessage());
            throw new AuraHandledException('Unable to search products. Please try again.');
        }
    }

    private static ProductOption mapPricebookEntryToProductOption(PricebookEntry pbe, Boolean pbeHasCost) {
        ProductOption option = new ProductOption();
        option.pricebookEntryId = pbe.Id;
        option.productId = pbe.Product2Id;
        option.productName = pbe.Product2.Name;
        option.productCode = pbe.Product2.ProductCode;
        option.description = pbe.Product2.Description;
        option.unitPrice = pbe.UnitPrice;
        option.cost = pbeHasCost ? (Decimal) pbe.get('Cost__c') : null;
        option.taxable = pbe.Product2.Is_Taxable__c;
        return option;
    }

    private static Boolean fieldExists(Schema.SObjectType typ, String fieldApi) {
        return typ.getDescribe().fields.getMap().containsKey(fieldApi);
    }

    public static SaveResult createDraftInvoice(SaveRequest request) {
        validateRequest(request);

        fax__Invoice__c invoiceRecord = new fax__Invoice__c();
        putIfCreateable(invoiceRecord, 'Order__c', resolveOrderId(request));
        putIfCreateable(invoiceRecord, 'fax__Site__c', request.accountId);
        putIfCreateable(invoiceRecord, 'fax__Contact__c', request.contactId);
        putIfCreateable(invoiceRecord, 'Sales_Person__c', request.ownerId);
        putIfCreateable(invoiceRecord, 'fax__Date__c', request.transactionDate == null ? Date.today() : request.transactionDate);
        putIfCreateable(invoiceRecord, 'fax__Due_Date__c', request.dueDate);
        String invoiceStatus = String.isBlank(request.status) ? DRAFT_INVOICE_STATUS : request.status;
        putIfCreateable(invoiceRecord, 'fax__Status__c', invoiceStatus);
        putIfCreateable(invoiceRecord, 'Class__c', request.classValue);
        putIfCreateable(invoiceRecord, 'fax__PO_Number__c', request.poNumber);
        putIfCreateable(invoiceRecord, 'fax__Terms__c', request.terms);
        putIfCreateable(invoiceRecord, 'Job_Category__c', request.jobCategory);
        putIfCreateable(invoiceRecord, 'fax__Street__c', request.billingStreet);
        putIfCreateable(invoiceRecord, 'fax__City__c', request.billingCity);
        putIfCreateable(invoiceRecord, 'fax__State__c', request.billingState);
        putIfCreateable(invoiceRecord, 'fax__Postal_Code__c', request.billingPostalCode);
        putIfCreateable(invoiceRecord, 'Job_Description__c', request.jobDescription);
        putIfCreateable(invoiceRecord, 'Job_Detail__c', request.jobDetail);
        putIfCreateable(invoiceRecord, 'Engineer_Completion_Notes__c', request.engineerCompletionNotes);
        putIfCreateable(invoiceRecord, 'Sync_to_Quickbooks__c', request.syncToQuickBooks == true);
        putIfCreateable(invoiceRecord, 'Send_to_QuickBooks__c', request.sendToQuickBooks == true);
        putIfCreateable(invoiceRecord, 'QuickBooks_Invoice_ID__c', request.quickBooksInvoiceId);

        try {
            insert invoiceRecord;

            List<fax__Invoice_Line_Item__c> linesToInsert = new List<fax__Invoice_Line_Item__c>();
            for (LineItem line : request.lines) {
           
                if (line == null || line.isDeleted == true) {
                    continue;
                }
                System.debug('Line>>>>>>>'+ line);
                fax__Invoice_Line_Item__c invoiceLine = new fax__Invoice_Line_Item__c(
                    fax__Invoice__c = invoiceRecord.Id,
                    fax__Product__c = line.productId,
                    fax__Qty__c = line.quantity,
                    fax__Unit_Price__c = line.unitPrice,
                    Description__c = line.description,
                    Include_In_Invoice__c = line.includeInInvoice != false
                );
                linesToInsert.add(invoiceLine);
            }
            insert linesToInsert;
        } catch (Exception e) {
            throw new AuraHandledException(extractDmlMessage(e));
        }

        SaveResult result = new SaveResult();
        result.invoiceId = invoiceRecord.Id;
        return result;
    }

    private static List<LineItem> buildLines(Id orderId) {
        List<LineItem> lines = new List<LineItem>();
        Integer index = 0;
        for (OrderItem item : [
            SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.Description,
                   Product2.Is_Taxable__c, Product2.Is_Installed_System__c, Quantity,
                   UnitPrice, Cost__c, TotalPrice, Description, Line_Description__c
            FROM OrderItem
            WHERE OrderId = :orderId
            AND Product2Id != null
            ORDER BY CreatedDate ASC
        ]) {
            if (item.Product2.Is_Installed_System__c == true) {
                continue;
            }
            LineItem line = new LineItem();
            line.key = 'order-' + String.valueOf(index++);
            line.orderItemId = item.Id;
            line.productId = item.Product2Id;
            line.productName = item.Product2.Name;
            line.productCode = item.Product2.ProductCode;
            line.description = String.isNotBlank(item.Line_Description__c) ? item.Line_Description__c : (String.isBlank(item.Description) ? item.Product2.Description : item.Description);
            line.quantity = item.Quantity;
            line.unitPrice = item.UnitPrice;
            line.cost = item.Cost__c;
            line.taxable = item.Product2.Is_Taxable__c;
            line.taxAmount = 0;
            line.total = calculateLineTotal(line.quantity, line.unitPrice);
            line.includeInInvoice = true;
            line.isDeleted = false;
            lines.add(line);
        }
        return lines;
    }

    private static void setEligibility(Workspace workspace) {
        List<String> reasons = new List<String>();
        if (!Schema.sObjectType.fax__Invoice__c.isCreateable()) {
            reasons.add('You do not have permission to create invoices.');
        }
        if (!Schema.sObjectType.fax__Invoice_Line_Item__c.isCreateable()) {
            reasons.add('You do not have permission to create invoice lines.');
        }
        if (workspace.accountId == null) {
            reasons.add('Order must have a customer account.');
        }
        if (!ELIGIBLE_ORDER_STATUSES.contains(workspace.orderStatus)) {
            reasons.add('Order status must be Approved or Ready for Invoice.');
        }
        if (workspace.lines == null || workspace.lines.isEmpty()) {
            reasons.add('Order must contain at least one non-installed product.');
        }
        workspace.eligible = reasons.isEmpty();
        workspace.eligibilityMessage = String.join(reasons, ' ');
    }

    private static void validateRequest(SaveRequest request) {
        if (request == null) {
            throw new AuraHandledException('Invoice request is required.');
        }
        if (request.accountId == null) {
            throw new AuraHandledException('Customer is required.');
        }
        if (String.isBlank(request.jobCategory)) {
            throw new AuraHandledException('Job Category is required.');
        }
        if (request.lines == null || request.lines.isEmpty()) {
            throw new AuraHandledException('At least one invoice line is required.');
        }

        Integer activeLines = 0;
        for (LineItem line : request.lines) {
            if (line == null || line.isDeleted == true) {
                continue;
            }
            activeLines++;
            if (line.productId == null) {
                throw new AuraHandledException('Each invoice line must have a product.');
            }
            if (line.quantity == null || line.quantity <= 0) {
                throw new AuraHandledException('Quantity must be greater than zero.');
            }
            if (line.unitPrice == null || line.unitPrice < 0) {
                throw new AuraHandledException('Unit price cannot be negative.');
            }
        }
        if (activeLines == 0) {
            throw new AuraHandledException('At least one invoice line is required.');
        }
    }

    private static void recalculateWorkspaceTotals(Workspace workspace) {
        Decimal subtotal = 0;
        if (workspace.lines != null) {
            for (LineItem line : workspace.lines) {
                if (line == null || line.isDeleted == true) {
                    continue;
                }
                line.total = calculateLineTotal(line.quantity, line.unitPrice);
                line.taxAmount = 0;
                subtotal += line.total;
            }
        }
        workspace.subtotal = subtotal.setScale(2);
        workspace.tax = 0;
        workspace.grandTotal = workspace.subtotal;
        workspace.paymentReceived = 0;
        workspace.amountDue = workspace.grandTotal;
    }

    private static Decimal calculateLineTotal(Decimal quantity, Decimal unitPrice) {
        Decimal qty = quantity == null ? 0 : quantity;
        Decimal price = unitPrice == null ? 0 : unitPrice;
        return (qty * price).setScale(2);
    }

    private static Date calculateDueDate(Date transactionDate, String terms) {
        Date baseDate = transactionDate == null ? Date.today() : transactionDate;
        if (String.isBlank(terms)) {
            return baseDate.addDays(30);
        }
        String normalized = terms.toLowerCase();
        if (normalized.contains('receipt') || normalized.contains('due on')) {
            return baseDate;
        }
        String digits = '';
        for (Integer i = 0; i < terms.length(); i++) {
            String c = terms.substring(i, i + 1);
            if (c >= '0' && c <= '9') {
                digits += c;
            }
        }
        return String.isBlank(digits) ? baseDate.addDays(30) : baseDate.addDays(Integer.valueOf(digits));
    }

    private static Id getStandardActivePricebookId() {
        List<Pricebook2> pricebooks = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = true
            AND IsActive = true
            LIMIT 1
        ];
        if (pricebooks.isEmpty()) {
            throw new AuraHandledException('Standard Price Book must be active before creating invoice lines.');
        }
        return pricebooks[0].Id;
    }

    private static Id resolveOrderId(SaveRequest request) {
        if (request == null || request.orderId == null) {
            return null;
        }
        if (request.orderId.getSObjectType() != Order.SObjectType) {
            return null;
        }
        return request.orderId;
    }

    private static void putIfCreateable(SObject record, String fieldName, Object value) {
        if (value == null) {
            return;
        }
        Map<String, Schema.SObjectField> fields = record.getSObjectType().getDescribe().fields.getMap();
        if (!fields.containsKey(fieldName)) {
            return;
        }
        Schema.DescribeFieldResult fieldDescribe = fields.get(fieldName).getDescribe();
        if (
            fieldDescribe.isCreateable() &&
            !fieldDescribe.isCalculated() &&
            !fieldDescribe.isAutoNumber()
        ) {
            record.put(fieldName, value);
        }
    }

    private static String extractDmlMessage(Exception e) {
        if (e instanceof DmlException) {
            DmlException dml = (DmlException) e;
            if (dml.getNumDml() > 0) {
                return dml.getDmlMessage(0);
            }
        }
        return e.getMessage();
    }
}