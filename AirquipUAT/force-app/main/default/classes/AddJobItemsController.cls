public with sharing class AddJobItemsController {

    private static final String PRODUCT_PURCHASE_COST_FIELD = 'faxa__Purchase_Cost__c';

    @AuraEnabled(cacheable=true)
    public static Map<String, String> getJobItemSelectorLabels() {
        return UILabelService.getJobItemSelectorLabels();
    }

    @AuraEnabled
    public static Boolean isMultiCurrencyOrg() {
        return UserInfo.isMultiCurrencyOrganization();
    }

    // Used by Aura to decide whether the selector is being opened from a Job or an Invoice.
    @AuraEnabled
    public static String getParentContext(Id recordId) {
        if (recordId == null) return 'JOB';
        Schema.SObjectType sType = recordId.getSObjectType();
        if (sType == fax__Job__c.SObjectType) return 'JOB';
        if (sType == fax__Invoice__c.SObjectType) return 'INVOICE';
        return 'JOB';
    }

    @AuraEnabled
    public static Id checkJobPricebook(Id jobId) {
        fax__Job__c job;
        if (Schema.sObjectType.fax__Job__c.isAccessible()
            && Schema.sObjectType.fax__Job__c.fields.Id.isAccessible()
            && Schema.sObjectType.fax__Job__c.fields.fax__Pricebook__c.isAccessible()) {

            job = [
                SELECT Id, fax__Pricebook__c
                FROM fax__Job__c
                WHERE Id = :jobId
                WITH USER_MODE
            ];
        }
        return job != null ? job.fax__Pricebook__c : null;
    }

    @AuraEnabled
    public static Boolean IsPricebookActive(Id pbId) {
        if (Schema.sObjectType.Pricebook2.isAccessible()
            && Schema.sObjectType.Pricebook2.fields.Id.isAccessible()
            && Schema.sObjectType.Pricebook2.fields.IsActive.isAccessible()) {

            return [
                SELECT Id, IsActive
                FROM Pricebook2
                WHERE Id = :pbId
                WITH USER_MODE
            ].IsActive;
        }
        return false;
    }

    @AuraEnabled
    public static List<Pricebook2> getPricebooks() {
        List<Pricebook2> pbs;
        if (Schema.sObjectType.Pricebook2.isAccessible()
            && Schema.sObjectType.Pricebook2.fields.Id.isAccessible()
            && Schema.sObjectType.Pricebook2.fields.Name.isAccessible()) {

            pbs = [
                SELECT Id, Name
                FROM Pricebook2
                WHERE IsActive = TRUE
                WITH USER_MODE
                LIMIT 100
            ];
        }
        return pbs;
    }

    @AuraEnabled
    public static String checkCurrencyCode(Id jobId) {
        // In this org the Job and Invoice objects don't expose CurrencyIsoCode
        // (single-currency setup / managed package), so we always return null.
        return null;
    }

    @AuraEnabled
    public static void updatePricebookOnJob(Id pricebookId, Id jobId) {
        if (Schema.sObjectType.fax__Job__c.isUpdateable()
            && Schema.sObjectType.fax__Job__c.fields.fax__Pricebook__c.isUpdateable()
            && Schema.sObjectType.fax__Job__c.isAccessible()
            && Schema.sObjectType.fax__Job__c.fields.Id.isAccessible()
            && Schema.sObjectType.fax__Job__c.fields.fax__Pricebook__c.isAccessible()) {

            fax__Job__c job = [
                SELECT Id, fax__Pricebook__c
                FROM fax__Job__c
                WHERE Id = :jobId
                WITH USER_MODE
            ];

            job.fax__Pricebook__c = pricebookId;

            try {
                update job;
            } catch (Exception e) {
                throw buildFieldAxException(e);
            }
        }
    }

    // ── Invoice Pricebook (optional) ─────────────────────────────────────

    @AuraEnabled
    public static Id checkInvoicePricebook(Id invoiceId) {
        if (invoiceId == null) return null;

        if (!Schema.sObjectType.fax__Invoice__c.isAccessible()
            || !Schema.sObjectType.fax__Invoice__c.fields.Id.isAccessible()) {
            return null;
        }

        // Use dynamic access to avoid compile-time dependency on the field being present.
        final String pbFieldApi = 'fax__Pricebook__c';
        if (!Schema.sObjectType.fax__Invoice__c.fields.getMap().containsKey(pbFieldApi)) {
            return null;
        }

        Schema.SObjectField pbField = Schema.sObjectType.fax__Invoice__c.fields.getMap().get(pbFieldApi);
        if (pbField == null || !pbField.getDescribe().isAccessible()) return null;

        String soql = 'SELECT Id, ' + pbFieldApi + ' FROM fax__Invoice__c WHERE Id = :invoiceId LIMIT 1';
        Map<String, Object> bindVars = new Map<String, Object>{ 'invoiceId' => invoiceId };
        fax__Invoice__c inv = (fax__Invoice__c) Database.queryWithBinds(soql, bindVars, AccessLevel.USER_MODE);
        return (Id)inv.get(pbFieldApi);
    }

    @AuraEnabled
    public static void updatePricebookOnInvoice(Id pricebookId, Id invoiceId) {
        if (invoiceId == null) return;

        if (!Schema.sObjectType.fax__Invoice__c.isUpdateable()
            || !Schema.sObjectType.fax__Invoice__c.fields.Id.isAccessible()) {
            return;
        }

        final String pbFieldApi = 'fax__Pricebook__c';
        if (!Schema.sObjectType.fax__Invoice__c.fields.getMap().containsKey(pbFieldApi)) {
            return;
        }

        Schema.SObjectField pbField = Schema.sObjectType.fax__Invoice__c.fields.getMap().get(pbFieldApi);
        if (pbField == null || !pbField.getDescribe().isUpdateable()) return;

        String soql = 'SELECT Id, ' + pbFieldApi + ' FROM fax__Invoice__c WHERE Id = :invoiceId LIMIT 1';
        Map<String, Object> bindVars = new Map<String, Object>{ 'invoiceId' => invoiceId };
        fax__Invoice__c inv = (fax__Invoice__c) Database.queryWithBinds(soql, bindVars, AccessLevel.USER_MODE);
        inv.put(pbFieldApi, pricebookId);

        try {
            update inv;
        } catch (Exception e) {
            throw buildFieldAxException(e);
        }
    }

    // ── Products filtered by Installed Systems ─────────────────────────────

    @AuraEnabled
    public static List<Product2> getProducts(Id jobId) {
        fax__Job__c job;

        if (Schema.sObjectType.fax__Job__c.isAccessible()
            && Schema.sObjectType.fax__Job__c.fields.Id.isAccessible()
            && Schema.sObjectType.fax__Job__c.fields.fax__Customer__c.isAccessible()) {

            job = [
                SELECT Id, fax__Customer__c
                FROM fax__Job__c
                WHERE Id = :jobId
                WITH USER_MODE
                LIMIT 1
            ];
        }

        if (job == null || job.fax__Customer__c == null)
            return new List<Product2>();

        Set<Id> installedProductIds = getInstalledProductIds(job.fax__Customer__c);

        if (installedProductIds.isEmpty())
            return new List<Product2>();

        return [
            SELECT Id, Name, Description, ProductCode
            FROM Product2
            WHERE Id IN :installedProductIds
            AND IsActive = true
            WITH USER_MODE
            LIMIT 200
        ];
    }

    // ── Invoice Products filtered by Installed Systems ────────────────────

    @AuraEnabled
    public static List<Product2> getInvoiceProducts(Id invoiceId) {
        fax__Invoice__c inv;

        if (Schema.sObjectType.fax__Invoice__c.isAccessible()
            && Schema.sObjectType.fax__Invoice__c.fields.Id.isAccessible()
            && Schema.sObjectType.fax__Invoice__c.fields.fax__Site__c.isAccessible()) {
            inv = [
                SELECT Id, fax__Site__c
                FROM fax__Invoice__c
                WHERE Id = :invoiceId
                WITH USER_MODE
                LIMIT 1
            ];
        }

        if (inv == null || inv.fax__Site__c == null) return new List<Product2>();

        Set<Id> installedProductIds = getInstalledProductIds(inv.fax__Site__c);
        if (installedProductIds.isEmpty()) return new List<Product2>();

        return [
            SELECT Id, Name, Description, ProductCode
            FROM Product2
            WHERE Id IN :installedProductIds
            AND IsActive = true
            WITH USER_MODE
            LIMIT 200
        ];
    }

    @AuraEnabled
    public static List<Product2> searchInvoiceProducts(Id invoiceId, String filter) {
        fax__Invoice__c inv;

        if (Schema.sObjectType.fax__Invoice__c.isAccessible()
            && Schema.sObjectType.fax__Invoice__c.fields.Id.isAccessible()
            && Schema.sObjectType.fax__Invoice__c.fields.fax__Site__c.isAccessible()) {
            inv = [
                SELECT Id, fax__Site__c
                FROM fax__Invoice__c
                WHERE Id = :invoiceId
                WITH USER_MODE
                LIMIT 1
            ];
        }

        if (inv == null || inv.fax__Site__c == null) return new List<Product2>();

        Set<Id> installedProductIds = getInstalledProductIds(inv.fax__Site__c);
        if (installedProductIds.isEmpty()) return new List<Product2>();

        String f = '%' + filter + '%';

        if (String.isBlank(filter)) {
            return [
                SELECT Id, Name, Description, ProductCode
                FROM Product2
                WHERE Id IN :installedProductIds
                AND IsActive = true
                WITH USER_MODE
                LIMIT 200
            ];
        }

        return [
            SELECT Id, Name, Description, ProductCode
            FROM Product2
            WHERE Id IN :installedProductIds
            AND IsActive = true
            AND (Name LIKE :f OR Description LIKE :f)
            WITH USER_MODE
            LIMIT 200
        ];
    }

    // ── All active products (no installed-system filter) ────────────────────

    @AuraEnabled
    public static List<Product2> getAllProducts() {
        if (Schema.sObjectType.Product2.isAccessible()
            && Schema.sObjectType.Product2.fields.Id.isAccessible()
            && Schema.sObjectType.Product2.fields.Name.isAccessible()) {

            return [
                SELECT Id, Name, Description, ProductCode
                FROM Product2
                WHERE IsActive = true
                WITH USER_MODE
                LIMIT 200
            ];
        }
        return new List<Product2>();
    }

    @AuraEnabled
    public static List<Product2> searchProducts(Id jobId, String filter) {
        fax__Job__c job;

        if (Schema.sObjectType.fax__Job__c.isAccessible()
            && Schema.sObjectType.fax__Job__c.fields.Id.isAccessible()
            && Schema.sObjectType.fax__Job__c.fields.fax__Customer__c.isAccessible()) {

            job = [
                SELECT Id, fax__Customer__c
                FROM fax__Job__c
                WHERE Id = :jobId
                WITH USER_MODE
                LIMIT 1
            ];
        }

        if (job == null || job.fax__Customer__c == null)
            return new List<Product2>();

        Set<Id> installedProductIds = getInstalledProductIds(job.fax__Customer__c);

        if (installedProductIds.isEmpty())
            return new List<Product2>();

        String f = '%' + filter + '%';

        if (String.isBlank(filter)) {
            return [
                SELECT Id, Name, Description, ProductCode
                FROM Product2
                WHERE Id IN :installedProductIds
                AND IsActive = true
                WITH USER_MODE
                LIMIT 200
            ];
        } else {
            return [
                SELECT Id, Name, Description, ProductCode
                FROM Product2
                WHERE Id IN :installedProductIds
                AND IsActive = true
                AND (Name LIKE :f OR Description LIKE :f OR ProductCode LIKE :f)
                WITH USER_MODE
                LIMIT 200
            ];
        }
    }

    @AuraEnabled
    public static List<Product2> searchAllProducts(String filter) {
        if (!Schema.sObjectType.Product2.isAccessible()
            || !Schema.sObjectType.Product2.fields.Id.isAccessible()
            || !Schema.sObjectType.Product2.fields.Name.isAccessible()) {
            return new List<Product2>();
        }

        String f = '%' + filter + '%';

        if (String.isBlank(filter)) {
            return [
                SELECT Id, Name, Description, ProductCode
                FROM Product2
                WHERE IsActive = true
                WITH USER_MODE
                LIMIT 200
            ];
        } else {
            return [
                SELECT Id, Name, Description, ProductCode
                FROM Product2
                WHERE IsActive = true
                AND (Name LIKE :f OR Description LIKE :f OR ProductCode LIKE :f)
                WITH USER_MODE
                LIMIT 200
            ];
        }
    }

    // ── Pricebook entries ──────────────────────────────────────────────────

    @AuraEnabled
    public static List<PricebookEntry> getProductsWithPricebookEntries(Id pricebookId, List<Id> productIds) {
        return [
            SELECT Id, Product2Id, UnitPrice, Product2.Name, Product2.Description
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
            AND Product2Id IN :productIds
            AND IsActive = TRUE
            WITH USER_MODE
        ];
    }

    @AuraEnabled
    public static List<PricebookEntry> getProductsWithPricebookEntriesByISOCode(
        Id pricebookId,
        List<Id> productIds,
        String currencyISOCode
    ) {
        String q = 'SELECT Id, Product2Id, UnitPrice, CurrencyIsoCode, Product2.Name, Product2.Description '
                 + 'FROM PricebookEntry '
                 + 'WHERE Pricebook2Id = :pricebookId '
                 + 'AND Product2Id IN :productIds '
                 + 'AND IsActive = TRUE '
                 + 'AND CurrencyIsoCode = :currencyISOCode';

        if (!Test.isRunningTest()) {
            Map<String, Object> bindVars = new Map<String, Object>{
                'pricebookId' => pricebookId,
                'productIds' => productIds,
                'currencyISOCode' => currencyISOCode
            };
            return Database.queryWithBinds(q, bindVars, AccessLevel.USER_MODE);
        }
        return null;
    }

    // ── Job Systems ────────────────────────────────────────────────────────

    @AuraEnabled
    public static List<fax__Job_System__c> createJobSystems(List<fax__Job_System__c> jobSystems) {

        Set<Id> jobIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();

        for (fax__Job_System__c js : jobSystems) {
            jobIds.add(js.fax__Job_New__c);
            productIds.add(js.fax__Product__c);
        }

        List<fax__Job_System__c> existing = [
            SELECT Id, fax__Job_New__c, fax__Product__c
            FROM fax__Job_System__c
            WHERE fax__Job_New__c IN :jobIds
            AND fax__Product__c IN :productIds
            WITH USER_MODE
        ];

        Map<String, fax__Job_System__c> existingKeyMap = new Map<String, fax__Job_System__c>();

        for (fax__Job_System__c item : existing) {
            existingKeyMap.put(item.fax__Job_New__c + '-' + item.fax__Product__c, item);
        }

        List<fax__Job_System__c> toInsert = new List<fax__Job_System__c>();

        for (fax__Job_System__c js : jobSystems) {
            if (!existingKeyMap.containsKey(js.fax__Job_New__c + '-' + js.fax__Product__c)) {
                toInsert.add(js);
            }
        }

        if (!toInsert.isEmpty()) {
            try {
                insert toInsert;
            } catch (Exception e) {
                throw buildFieldAxException(e);
            }
        }

        return toInsert;
    }

    // ── Invoice Line Items ───────────────────────────────────────────────

    @AuraEnabled
    public static List<fax__Invoice_Line_Item__c> createInvoiceLineItems(List<fax__Invoice_Line_Item__c> invoiceLineItems) {
        if (invoiceLineItems == null || invoiceLineItems.isEmpty()) {
            return new List<fax__Invoice_Line_Item__c>();
        }

        Set<Id> invoiceIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();

        for (fax__Invoice_Line_Item__c li : invoiceLineItems) {
            invoiceIds.add(li.fax__Invoice__c);
            productIds.add(li.fax__Product__c);
        }

        List<fax__Invoice_Line_Item__c> existing = [
            SELECT Id, fax__Invoice__c, fax__Product__c
            FROM fax__Invoice_Line_Item__c
            WHERE fax__Invoice__c IN :invoiceIds
            AND fax__Product__c IN :productIds
            WITH USER_MODE
        ];

        Map<String, fax__Invoice_Line_Item__c> existingKeyMap = new Map<String, fax__Invoice_Line_Item__c>();
        for (fax__Invoice_Line_Item__c item : existing) {
            existingKeyMap.put(item.fax__Invoice__c + '-' + item.fax__Product__c, item);
        }

        Map<Id, String> productIdToDescription = new Map<Id, String>();
        for (Product2 p : [
            SELECT Id, Description
            FROM Product2
            WHERE Id IN :productIds
        ]) {
            productIdToDescription.put(p.Id, p.Description);
        }

        List<fax__Invoice_Line_Item__c> toInsert = new List<fax__Invoice_Line_Item__c>();

        for (fax__Invoice_Line_Item__c li : invoiceLineItems) {
            String key = li.fax__Invoice__c + '-' + li.fax__Product__c;
            if (existingKeyMap.containsKey(key)) continue;

            // Ensure required fields for downstream tax + invoice rendering.
            li.Include_In_Invoice__c = true;
            if (String.isBlank(li.Description__c)) {
                li.Description__c = productIdToDescription.get(li.fax__Product__c);
            }

            Decimal qty = li.fax__Qty__c != null ? li.fax__Qty__c : 0;
            Decimal unitPrice = li.fax__Unit_Price__c != null ? li.fax__Unit_Price__c : 0;
            Decimal discountPct = li.fax__Discount__c != null ? li.fax__Discount__c : 0;

            toInsert.add(li);
        }

        if (!toInsert.isEmpty()) {
            try {
                insert toInsert;
            } catch (Exception e) {
                throw buildFieldAxException(e);
            }
        }

        return toInsert;
    }

    // ── Inline Add/Edit Grid ───────────────────────────────────────────────

    public class GridLineRow {
        @AuraEnabled public String rowKey { get; set; }
        @AuraEnabled public Id rowId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String productDisplayName { get; set; }
        @AuraEnabled public Id installedSystemId { get; set; }
        @AuraEnabled public String installedItem { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal listPrice { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public Decimal discount { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Boolean isDeleted { get; set; }
        @AuraEnabled public Boolean includeInInvoice { get; set; }
    }

    public class InstalledItemOption {
        @AuraEnabled public Id installedSystemId { get; set; }
        @AuraEnabled public Id productId { get; set; }
        @AuraEnabled public String serialNumber { get; set; }
        @AuraEnabled public String productName { get; set; }
        @AuraEnabled public String productCode { get; set; }
        @AuraEnabled public String productDescription { get; set; }
    }

    public class PricebookResolution {
        @AuraEnabled public Id pricebookId { get; set; }
        @AuraEnabled public String pricebookName { get; set; }
        @AuraEnabled public Boolean assignedToRecord { get; set; }
    }

    public class JobItemSelectorInit {
        @AuraEnabled public String parentContext { get; set; }
        @AuraEnabled public Id pricebookId { get; set; }
        @AuraEnabled public String pricebookName { get; set; }
        @AuraEnabled public Boolean pricebookAssigned { get; set; }
        @AuraEnabled public List<GridLineRow> lineRows { get; set; }
    }

    @AuraEnabled
    public static PricebookResolution ensurePricebookForRecord(Id recordId) {
        PricebookResolution resolution = new PricebookResolution();
        resolution.assignedToRecord = false;

        if (recordId == null) {
            return resolution;
        }

        String parentContext = getParentContext(recordId);
        Id pricebookId = parentContext == 'INVOICE'
            ? checkInvoicePricebook(recordId)
            : checkJobPricebook(recordId);

        if (pricebookId != null && IsPricebookActive(pricebookId)) {
            resolution.pricebookId = pricebookId;
        } else {
            pricebookId = getFallbackPricebookId();
            if (pricebookId == null) {
                return resolution;
            }

            resolution.pricebookId = pricebookId;
            resolution.assignedToRecord = tryAssignPricebook(recordId, parentContext, pricebookId);
        }

        if (resolution.pricebookId != null
            && Schema.sObjectType.Pricebook2.isAccessible()
            && Schema.sObjectType.Pricebook2.fields.Name.isAccessible()) {
            List<Pricebook2> pricebooks = [
                SELECT Name
                FROM Pricebook2
                WHERE Id = :resolution.pricebookId
                WITH USER_MODE
                LIMIT 1
            ];
            resolution.pricebookName = pricebooks.isEmpty() ? null : pricebooks[0].Name;
        }

        return resolution;
    }

    @AuraEnabled
    public static JobItemSelectorInit initializeJobItemSelector(Id recordId) {
        JobItemSelectorInit init = new JobItemSelectorInit();
        if (recordId == null) {
            init.parentContext = 'JOB';
            init.lineRows = new List<GridLineRow>();
            return init;
        }

        init.parentContext = getParentContext(recordId);
        PricebookResolution pricebook = ensurePricebookForRecord(recordId);
        init.pricebookId = pricebook.pricebookId;
        init.pricebookName = pricebook.pricebookName;
        init.pricebookAssigned = pricebook.assignedToRecord == true;
        init.lineRows = getLineItemsForGrid(recordId);
        return init;
    }

    @AuraEnabled
    public static List<GridLineRow> getLineItemsForGrid(Id recordId) {
        if (recordId == null) return new List<GridLineRow>();

        String parentContext = getParentContext(recordId);
        List<GridLineRow> rows = new List<GridLineRow>();
        Map<Id, InstalledItemInfo> productIdToInstalledItem = getInstalledItemByProduct(recordId);

        if (parentContext == 'INVOICE') {
            for (fax__Invoice_Line_Item__c line : [
                SELECT Id,
                       fax__Product__c,
                       fax__Product__r.Name,
                       fax__Product__r.ProductCode,
                       fax__Product__r.Description,
                       fax__Product__r.faxa__Purchase_Cost__c,
                       fax__Qty__c,
                       fax__Unit_Price__c,
                       fax__Discount__c,
                       Description__c,
                       Include_In_Invoice__c
                FROM fax__Invoice_Line_Item__c
                WHERE fax__Invoice__c = :recordId
                WITH USER_MODE
                ORDER BY CreatedDate ASC
            ]) {
                GridLineRow row = new GridLineRow();
                row.rowKey = String.valueOf(line.Id);
                row.rowId = line.Id;
                row.productId = line.fax__Product__c;
                row.productName = line.fax__Product__r != null ? line.fax__Product__r.Name : null;
                row.productCode = line.fax__Product__r != null ? line.fax__Product__r.ProductCode : null;
                row.productDisplayName = cleanProductDisplayName(row.productName, row.productCode);
                InstalledItemInfo installedItem = productIdToInstalledItem.get(line.fax__Product__c);
                if (installedItem != null) {
                    row.installedSystemId = installedItem.installedSystemId;
                    row.installedItem = installedItem.serialNumbers;
                }
                row.description = String.isNotBlank(line.Description__c)
                    ? line.Description__c
                    : (line.fax__Product__r != null ? line.fax__Product__r.Description : null);
                row.quantity = line.fax__Qty__c;
                row.cost = getProductCost(line.fax__Product__r);
                row.includeInInvoice = line.Include_In_Invoice__c != false;
                row.unitPrice = row.includeInInvoice ? line.fax__Unit_Price__c : 0;
                row.listPrice = line.fax__Unit_Price__c;
                row.discount = line.fax__Discount__c;
                row.amount = calculateAmount(row.quantity, row.unitPrice, row.discount);
                row.isDeleted = false;
                rows.add(row);
            }
        } else {
            List<fax__Job_System__c> jobLines = queryJobSystemsForGrid(recordId);
            for (fax__Job_System__c line : jobLines) {
                GridLineRow row = new GridLineRow();
                row.rowKey = String.valueOf(line.Id);
                row.rowId = line.Id;
                row.productId = line.fax__Product__c;
                row.productName = line.fax__Product__r != null ? line.fax__Product__r.Name : null;
                row.productCode = line.fax__Product__r != null ? line.fax__Product__r.ProductCode : null;
                row.productDisplayName = cleanProductDisplayName(row.productName, row.productCode);
                row.installedSystemId = line.fax__Installed_System__c;
                row.installedItem = line.fax__Installed_System__r != null
                    ? line.fax__Installed_System__r.fax__Serial_Number__c
                    : null;
                if (String.isBlank(row.installedItem)) {
                    InstalledItemInfo installedItem = productIdToInstalledItem.get(line.fax__Product__c);
                    if (installedItem != null) {
                        row.installedSystemId = installedItem.installedSystemId;
                        row.installedItem = installedItem.serialNumbers;
                    }
                }
                row.description = getJobLineDescription(line);
                row.quantity = line.fax__Quantity__c;
                row.cost = getProductCost(line.fax__Product__r);
                row.listPrice = line.fax__List_Pricce__c;
                row.unitPrice = line.fax__Unit_Price__c;
                row.discount = line.fax__Discount__c;
                row.amount = calculateAmount(row.quantity, row.unitPrice, row.discount);
                row.isDeleted = false;
                rows.add(row);
            }
        }

        return rows;
    }

    @AuraEnabled
    public static List<GridLineRow> searchProductsForGrid(
        Id recordId,
        String keyword,
        String dataSource,
        Id pricebookId
    ) {
        if (recordId == null || String.isBlank(keyword)) {
            return new List<GridLineRow>();
        }

        try {
            return searchProductsForGridInternal(recordId, keyword.trim(), dataSource, pricebookId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Product search failed: ' + e.getMessage());
        }
    }

    private static Id resolvePricebookIdForSearch(Id recordId, Id cachedPricebookId) {
        if (cachedPricebookId != null && IsPricebookActive(cachedPricebookId)) {
            return cachedPricebookId;
        }

        String parentContext = getParentContext(recordId);
        Id pricebookId = parentContext == 'INVOICE'
            ? checkInvoicePricebook(recordId)
            : checkJobPricebook(recordId);

        if (pricebookId != null && IsPricebookActive(pricebookId)) {
            return pricebookId;
        }

        return getFallbackPricebookId();
    }

    private static List<GridLineRow> searchProductsForGridInternal(
        Id recordId,
        String keyword,
        String dataSource,
        Id cachedPricebookId
    ) {
        Id pricebookId = resolvePricebookIdForSearch(recordId, cachedPricebookId);
        if (pricebookId == null) {
            return new List<GridLineRow>();
        }

        Set<Id> installedProductFilter = null;
        if (dataSource == 'INSTALLED_PRODUCTS') {
            Id siteAccountId = getSiteAccountId(recordId);
            if (siteAccountId == null) {
                return new List<GridLineRow>();
            }
            installedProductFilter = getInstalledProductIds(siteAccountId);
            if (installedProductFilter.isEmpty()) {
                return new List<GridLineRow>();
            }
        }

        List<PricebookEntry> entries = searchPricebookEntriesForGrid(
            pricebookId,
            keyword,
            installedProductFilter
        );
        Map<Id, InstalledItemInfo> productIdToInstalledItem = getInstalledItemByProductSafe(recordId);

        List<GridLineRow> results = new List<GridLineRow>();
        for (PricebookEntry entry : entries) {
            if (entry.Product2Id == null) {
                continue;
            }

            Decimal unitPrice = entry.UnitPrice != null ? entry.UnitPrice : 0;
            GridLineRow row = new GridLineRow();
            row.rowKey = 'product-' + String.valueOf(entry.Product2Id);
            row.productId = entry.Product2Id;
            row.productName = entry.Product2 != null ? entry.Product2.Name : null;
            row.productCode = entry.Product2 != null ? entry.Product2.ProductCode : null;
            row.productDisplayName = cleanProductDisplayName(row.productName, row.productCode);
            InstalledItemInfo installedItem = productIdToInstalledItem.get(entry.Product2Id);
            if (installedItem != null) {
                row.installedSystemId = installedItem.installedSystemId;
                row.installedItem = installedItem.serialNumbers;
            }
            row.description = entry.Product2 != null ? getProductDescription(entry.Product2) : null;
            row.quantity = 1;
            row.cost = getProductCost(entry.Product2);
            row.listPrice = unitPrice;
            row.unitPrice = unitPrice;
            row.discount = 0;
            row.amount = calculateAmount(row.quantity, row.unitPrice, row.discount);
            row.isDeleted = false;
            if (getParentContext(recordId) == 'INVOICE') {
                row.includeInInvoice = true;
            }
            results.add(row);
        }

        return results;
    }

    @TestVisible
    private static List<PricebookEntry> getActivePricebookEntries(Id pricebookId, Set<Id> productIdFilter) {
        if (pricebookId == null) {
            return new List<PricebookEntry>();
        }
        if (!Schema.sObjectType.PricebookEntry.isAccessible()) {
            return new List<PricebookEntry>();
        }

        if (productIdFilter != null && !productIdFilter.isEmpty()) {
            return [
                SELECT Product2Id,
                       UnitPrice,
                       Product2.Name,
                       Product2.ProductCode,
                       Product2.Description,
                       Product2.faxa__Purchase_Cost__c
                FROM PricebookEntry
                WHERE Pricebook2Id = :pricebookId
                AND IsActive = true
                AND Product2Id IN :productIdFilter
                WITH USER_MODE
            ];
        }

        return [
            SELECT Product2Id,
                   UnitPrice,
                   Product2.Name,
                   Product2.ProductCode,
                   Product2.Description,
                   Product2.faxa__Purchase_Cost__c
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
            AND IsActive = true
            WITH USER_MODE
        ];
    }

    private static List<PricebookEntry> searchPricebookEntriesForGrid(
        Id pricebookId,
        String keyword,
        Set<Id> productIdFilter
    ) {
        if (pricebookId == null || String.isBlank(keyword)) {
            return new List<PricebookEntry>();
        }
        if (!Schema.sObjectType.PricebookEntry.isAccessible()) {
            return new List<PricebookEntry>();
        }

        String keywordLower = keyword.trim().toLowerCase();
        List<PricebookEntry> scopedEntries = getActivePricebookEntries(pricebookId, productIdFilter);

        List<PricebookEntry> matches = new List<PricebookEntry>();
        for (PricebookEntry entry : scopedEntries) {
            if (matchesProductKeyword(entry, keywordLower)) {
                matches.add(entry);
                if (matches.size() >= 200) {
                    break;
                }
            }
        }

        matches.sort(new PricebookEntryNameComparator());
        return matches;
    }

    private class PricebookEntryNameComparator implements Comparator<PricebookEntry> {
        public Integer compare(PricebookEntry left, PricebookEntry right) {
            String leftName = left != null && left.Product2 != null ? left.Product2.Name : null;
            String rightName = right != null && right.Product2 != null ? right.Product2.Name : null;
            if (leftName == null && rightName == null) {
                return 0;
            }
            if (leftName == null) {
                return 1;
            }
            if (rightName == null) {
                return -1;
            }
            return leftName.toLowerCase().compareTo(rightName.toLowerCase());
        }
    }

    private static Boolean matchesProductKeyword(PricebookEntry entry, String keywordLower) {
        if (String.isBlank(keywordLower)) {
            return true;
        }

        String name = entry.Product2 != null && entry.Product2.Name != null
            ? entry.Product2.Name.toLowerCase()
            : '';
        String code = entry.Product2 != null && entry.Product2.ProductCode != null
            ? entry.Product2.ProductCode.toLowerCase()
            : '';
        String description = entry.Product2 != null && entry.Product2.Description != null
            ? entry.Product2.Description.toLowerCase()
            : '';

        return name.contains(keywordLower)
            || code.contains(keywordLower)
            || description.contains(keywordLower);
    }

    @AuraEnabled
    public static List<GridLineRow> saveLineItemsForGrid(Id recordId, List<GridLineRow> rows) {
        if (recordId == null) return new List<GridLineRow>();
        if (rows == null) rows = new List<GridLineRow>();

        String parentContext = getParentContext(recordId);

        if (parentContext == 'INVOICE') {
            saveInvoiceGridRows(recordId, rows);
        } else {
            saveJobGridRows(recordId, rows);
        }

        return getLineItemsForGrid(recordId);
    }

    @AuraEnabled
    public static List<InstalledItemOption> searchInstalledItemsForGrid(Id recordId, String keyword) {
        List<InstalledItemOption> options = new List<InstalledItemOption>();
        Id siteAccountId = getSiteAccountId(recordId);
        if (siteAccountId == null) return options;

        String normalizedKeyword = String.isBlank(keyword) ? null : '%' + keyword.trim() + '%';
        List<fax__Installed_System__c> installedSystems;
        if (normalizedKeyword == null) {
            installedSystems = [
                SELECT Id,
                       fax__Serial_Number__c,
                       fax__System_Name__c,
                       fax__System_Name__r.Name,
                       fax__System_Name__r.ProductCode,
                       fax__System_Name__r.Description
                FROM fax__Installed_System__c
                WHERE fax__Site__c = :siteAccountId
                AND fax__Serial_Number__c != null
                WITH USER_MODE
                ORDER BY fax__Serial_Number__c ASC
                LIMIT 50
            ];
        } else {
            installedSystems = [
                SELECT Id,
                       fax__Serial_Number__c,
                       fax__System_Name__c,
                       fax__System_Name__r.Name,
                       fax__System_Name__r.ProductCode,
                       fax__System_Name__r.Description
                FROM fax__Installed_System__c
                WHERE fax__Site__c = :siteAccountId
                AND fax__Serial_Number__c != null
                AND (
                    fax__Serial_Number__c LIKE :normalizedKeyword
                    OR fax__System_Name__r.Name LIKE :normalizedKeyword
                    OR fax__System_Name__r.Description LIKE :normalizedKeyword
                )
                WITH USER_MODE
                ORDER BY fax__Serial_Number__c ASC
                LIMIT 50
            ];
        }

        for (fax__Installed_System__c installedSystem : installedSystems) {
            InstalledItemOption option = new InstalledItemOption();
            option.installedSystemId = installedSystem.Id;
            option.productId = installedSystem.fax__System_Name__c;
            option.serialNumber = installedSystem.fax__Serial_Number__c;
            option.productName = installedSystem.fax__System_Name__r != null
                ? installedSystem.fax__System_Name__r.Name
                : null;
            option.productCode = installedSystem.fax__System_Name__r != null
                ? installedSystem.fax__System_Name__r.ProductCode
                : null;
            option.productDescription = installedSystem.fax__System_Name__r != null
                ? installedSystem.fax__System_Name__r.Description
                : null;
            options.add(option);
        }

        return options;
    }

    private static void saveJobGridRows(Id jobId, List<GridLineRow> rows) {
        List<fax__Job_System__c> toInsert = new List<fax__Job_System__c>();
        List<fax__Job_System__c> toUpdate = new List<fax__Job_System__c>();
        List<fax__Job_System__c> toDelete = new List<fax__Job_System__c>();

        Set<Id> productIds = new Set<Id>();
        for (GridLineRow row : rows) {
            if (row != null && row.productId != null) productIds.add(row.productId);
        }

        Map<Id, fax__Job_System__c> existingByProduct = new Map<Id, fax__Job_System__c>();
        Map<Id, Product2> productsById = getProductsById(productIds);
        if (!productIds.isEmpty()) {
            for (fax__Job_System__c existing : [
                SELECT Id, fax__Product__c
                FROM fax__Job_System__c
                WHERE fax__Job_New__c = :jobId
                AND fax__Product__c IN :productIds
            ]) {
                existingByProduct.put(existing.fax__Product__c, existing);
            }
        }

        Set<Id> updatedIds = new Set<Id>();
        for (GridLineRow row : rows) {
            if (row == null) continue;

            if (row.isDeleted == true) {
                if (row.rowId != null) toDelete.add(new fax__Job_System__c(Id = row.rowId));
                continue;
            }

            if (row.productId == null) continue;

            Id targetId = row.rowId;
            if (targetId == null && existingByProduct.containsKey(row.productId)) {
                targetId = existingByProduct.get(row.productId).Id;
            }

            fax__Job_System__c line = new fax__Job_System__c(
                fax__Job_New__c = jobId,
                fax__Product__c = row.productId,
                fax__Installed_System__c = row.installedSystemId,
                fax__Quantity__c = row.quantity,
                fax__List_Pricce__c = row.listPrice,
                fax__Unit_Price__c = row.unitPrice,
                fax__Discount__c = row.discount
            );
            setJobLineDescription(line, resolveJobLineDescriptionForSave(row, productsById));

            if (targetId != null) {
                if (updatedIds.contains(targetId)) continue;
                line.Id = targetId;
                toUpdate.add(line);
                updatedIds.add(targetId);
            } else {
                toInsert.add(line);
            }
        }

        try {
            if (!toDelete.isEmpty()) delete toDelete;
            if (!toUpdate.isEmpty()) update toUpdate;
            if (!toInsert.isEmpty()) insert toInsert;
        } catch (Exception e) {
            throw buildFieldAxException(e);
        }
    }

    private static void saveInvoiceGridRows(Id invoiceId, List<GridLineRow> rows) {
        List<fax__Invoice_Line_Item__c> toInsert = new List<fax__Invoice_Line_Item__c>();
        List<fax__Invoice_Line_Item__c> toUpdate = new List<fax__Invoice_Line_Item__c>();
        List<fax__Invoice_Line_Item__c> toDelete = new List<fax__Invoice_Line_Item__c>();

        Set<Id> productIds = new Set<Id>();
        for (GridLineRow row : rows) {
            if (row != null && row.productId != null) productIds.add(row.productId);
        }

        Map<Id, fax__Invoice_Line_Item__c> existingByProduct = new Map<Id, fax__Invoice_Line_Item__c>();
        if (!productIds.isEmpty()) {
            for (fax__Invoice_Line_Item__c existing : [
                SELECT Id, fax__Product__c
                FROM fax__Invoice_Line_Item__c
                WHERE fax__Invoice__c = :invoiceId
                AND fax__Product__c IN :productIds
            ]) {
                existingByProduct.put(existing.fax__Product__c, existing);
            }
        }

        Set<Id> updatedIds = new Set<Id>();
        for (GridLineRow row : rows) {
            if (row == null) continue;

            if (row.isDeleted == true) {
                if (row.rowId != null) toDelete.add(new fax__Invoice_Line_Item__c(Id = row.rowId));
                continue;
            }

            if (row.productId == null) continue;

            Id targetId = row.rowId;
            if (targetId == null && existingByProduct.containsKey(row.productId)) {
                targetId = existingByProduct.get(row.productId).Id;
            }

            Boolean includeInInvoice = row.includeInInvoice == null ? true : row.includeInInvoice;
            Decimal unitPrice = includeInInvoice ? row.unitPrice : 0;

            fax__Invoice_Line_Item__c line = new fax__Invoice_Line_Item__c(
                fax__Invoice__c = invoiceId,
                fax__Product__c = row.productId,
                fax__Qty__c = row.quantity,
                fax__Unit_Price__c = unitPrice,
                fax__Discount__c = row.discount,
                Description__c = row.description,
                Include_In_Invoice__c = includeInInvoice
            );

            if (targetId != null) {
                if (updatedIds.contains(targetId)) continue;
                line.Id = targetId;
                toUpdate.add(line);
                updatedIds.add(targetId);
            } else {
                toInsert.add(line);
            }
        }

        try {
            if (!toDelete.isEmpty()) delete toDelete;
            if (!toUpdate.isEmpty()) update toUpdate;
            if (!toInsert.isEmpty()) insert toInsert;
        } catch (Exception e) {
            throw buildFieldAxException(e);
        }
    }

    private static Decimal calculateAmount(Decimal quantity, Decimal unitPrice, Decimal discount) {
        Decimal qty = quantity == null ? 0 : quantity;
        Decimal price = unitPrice == null ? 0 : unitPrice;
        Decimal discountPct = discount == null ? 0 : discount;
        Decimal amount = qty * price;
        if (discountPct != 0) {
            amount = amount - (amount * discountPct / 100);
        }
        return amount.setScale(2);
    }

    private static String cleanProductDisplayName(String productName, String productCode) {
        if (String.isBlank(productName) || String.isBlank(productCode)) {
            return productName;
        }
        String withDash = productCode + ' - ';
        if (productName.startsWith(withDash)) {
            return productName.substring(withDash.length());
        }
        String withSpace = productCode + ' ';
        if (productName.startsWith(withSpace)) {
            return productName.substring(withSpace.length());
        }
        return productName;
    }

    private static List<fax__Job_System__c> queryJobSystemsForGrid(Id jobId) {
        return [
            SELECT Id,
                   fax__Product__c,
                   fax__Product__r.Name,
                   fax__Product__r.ProductCode,
                   fax__Product__r.Description,
                   fax__Product__r.faxa__Purchase_Cost__c,
                   Engineer_Comments__c,
                   fax__Quantity__c,
                   fax__List_Pricce__c,
                   fax__Unit_Price__c,
                   fax__Discount__c,
                   fax__Installed_System__c,
                   fax__Installed_System__r.fax__Serial_Number__c
            FROM fax__Job_System__c
            WHERE fax__Job_New__c = :jobId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];
    }

    private static Boolean tryAssignPricebook(Id recordId, String parentContext, Id pricebookId) {
        if (recordId == null || pricebookId == null) {
            return false;
        }

        try {
            if (parentContext == 'JOB'
                && Schema.sObjectType.fax__Job__c.isUpdateable()
                && Schema.sObjectType.fax__Job__c.fields.fax__Pricebook__c.isUpdateable()) {
                updatePricebookOnJob(pricebookId, recordId);
                return true;
            }
            if (parentContext == 'INVOICE') {
                updatePricebookOnInvoice(pricebookId, recordId);
                return true;
            }
        } catch (Exception e) {
            return false;
        }

        return false;
    }

    private static Map<Id, InstalledItemInfo> getInstalledItemByProductSafe(Id recordId) {
        try {
            return getInstalledItemByProduct(recordId);
        } catch (Exception e) {
            return new Map<Id, InstalledItemInfo>();
        }
    }

    private static Boolean fieldExists(Schema.SObjectType sObjectType, String fieldApiName) {
        return sObjectType.getDescribe().fields.getMap().containsKey(fieldApiName.toLowerCase());
    }

    private static Decimal getProductCost(SObject product) {
        if (product == null || !fieldExists(Product2.SObjectType, PRODUCT_PURCHASE_COST_FIELD)) {
            return null;
        }
        return (Decimal) product.get(PRODUCT_PURCHASE_COST_FIELD);
    }

    private static String getJobLineDescription(fax__Job_System__c line) {
        if (line == null) {
            return null;
        }
        if (fieldExists(fax__Job_System__c.SObjectType, 'Engineer_Comments__c')) {
            String comments = (String) line.get('Engineer_Comments__c');
            if (String.isNotBlank(comments)) {
                return comments;
            }
        }
        return getProductDescription(line.fax__Product__r);
    }

    private static String resolveJobLineDescriptionForSave(
        GridLineRow row,
        Map<Id, Product2> productsById
    ) {
        if (row == null) {
            return null;
        }
        if (String.isNotBlank(row.description)) {
            return row.description;
        }
        Product2 product = productsById != null ? productsById.get(row.productId) : null;
        return getProductDescription(product);
    }

    private static String getProductDescription(SObject product) {
        if (product == null) {
            return null;
        }
        return (String) product.get('Description');
    }

    private static Map<Id, Product2> getProductsById(Set<Id> productIds) {
        Map<Id, Product2> productsById = new Map<Id, Product2>();
        if (productIds == null || productIds.isEmpty()) {
            return productsById;
        }
        for (Product2 product : [
            SELECT Id, Description
            FROM Product2
            WHERE Id IN :productIds
            WITH USER_MODE
        ]) {
            productsById.put(product.Id, product);
        }
        return productsById;
    }

    private static void setJobLineDescription(fax__Job_System__c line, String description) {
        if (line == null || !fieldExists(fax__Job_System__c.SObjectType, 'Engineer_Comments__c')) {
            return;
        }
        line.put('Engineer_Comments__c', description);
    }

    private static Id getFallbackPricebookId() {
        List<Pricebook2> standardBooks = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = true
            AND IsActive = true
            LIMIT 1
        ];
        if (!standardBooks.isEmpty()) return standardBooks[0].Id;

        List<Pricebook2> activeBooks = [
            SELECT Id
            FROM Pricebook2
            WHERE IsActive = true
            LIMIT 1
        ];
        return activeBooks.isEmpty() ? null : activeBooks[0].Id;
    }

    // ── Private helpers ────────────────────────────────────────────────────

    private static Set<Id> getInstalledProductIds(Id customerId) {
        Set<Id> installedProductIds = new Set<Id>();

        for (fax__Installed_System__c sys : [
            SELECT fax__System_Name__c
            FROM fax__Installed_System__c
            WHERE fax__Site__c = :customerId
            AND fax__System_Name__c != null
            WITH USER_MODE
        ]) {
            installedProductIds.add(sys.fax__System_Name__c);
        }

        return installedProductIds;
    }

    private class InstalledItemInfo {
        Id installedSystemId;
        String serialNumbers;
    }

    private static Map<Id, InstalledItemInfo> getInstalledItemByProduct(Id recordId) {
        Map<Id, InstalledItemInfo> productIdToInstalledItem = new Map<Id, InstalledItemInfo>();
        Id siteAccountId = getSiteAccountId(recordId);
        if (siteAccountId == null) return productIdToInstalledItem;

        Map<Id, List<String>> productIdToSerials = new Map<Id, List<String>>();
        Map<Id, Id> productIdToFirstInstalledSystemId = new Map<Id, Id>();
        for (fax__Installed_System__c sys : [
            SELECT Id, fax__System_Name__c, fax__Serial_Number__c
            FROM fax__Installed_System__c
            WHERE fax__Site__c = :siteAccountId
            AND fax__System_Name__c != null
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            if (String.isBlank(sys.fax__Serial_Number__c)) continue;

            if (!productIdToSerials.containsKey(sys.fax__System_Name__c)) {
                productIdToSerials.put(sys.fax__System_Name__c, new List<String>());
                productIdToFirstInstalledSystemId.put(sys.fax__System_Name__c, sys.Id);
            }
            productIdToSerials.get(sys.fax__System_Name__c).add(sys.fax__Serial_Number__c);
        }

        for (Id productId : productIdToSerials.keySet()) {
            InstalledItemInfo info = new InstalledItemInfo();
            info.installedSystemId = productIdToFirstInstalledSystemId.get(productId);
            info.serialNumbers = String.join(productIdToSerials.get(productId), ', ');
            productIdToInstalledItem.put(productId, info);
        }

        return productIdToInstalledItem;
    }

    private static Id getSiteAccountId(Id recordId) {
        if (recordId == null) return null;

        String parentContext = getParentContext(recordId);
        if (parentContext == 'INVOICE') {
            List<fax__Invoice__c> invoices = [
                SELECT fax__Site__c
                FROM fax__Invoice__c
                WHERE Id = :recordId
                WITH USER_MODE
                LIMIT 1
            ];
            return invoices.isEmpty() ? null : invoices[0].fax__Site__c;
        }

        List<fax__Job__c> jobs = [
            SELECT fax__Customer__c
            FROM fax__Job__c
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        return jobs.isEmpty() ? null : jobs[0].fax__Customer__c;
    }

    private static FieldAxException buildFieldAxException(Exception e) {
        String msg = e.getMessage();

        if (msg.contains('FIELD_CUSTOM_VALIDATION_EXCEPTION')) {
            if (msg.contains('Duplicates are not allowed'))
                return new FieldAxException(System.label.Custom_Error_Msg_Duplicate_Serial_Numbers);

            if (msg.contains(System.label.Custom_Error_Msg_Serial_Number_Required))
                return new FieldAxException(System.label.Custom_Error_Msg_Serial_Number_Required);

            if (msg.contains(System.label.Custom_Err_Msg_serial_number_of_the_replaced_item))
                return new FieldAxException(System.label.Custom_Err_Msg_serial_number_of_the_replaced_item);

            if (msg.contains(System.label.Custom_Err_Msg_Serial_Number_Is_Required))
                return new FieldAxException(System.label.Custom_Err_Msg_Serial_Number_Is_Required);
        }

        return new FieldAxException(msg);
    }
}