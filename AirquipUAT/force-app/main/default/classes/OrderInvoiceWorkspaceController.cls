public with sharing class OrderInvoiceWorkspaceController {
    @AuraEnabled(cacheable=true)
    public static OrderInvoiceService.Workspace getWorkspace(Id orderId) {
        try {
            return OrderInvoiceService.getWorkspace(orderId);
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<OrderInvoiceService.ProductOption> searchStandardProducts(String searchTerm) {
        try {
            return OrderInvoiceService.searchStandardProducts(searchTerm);
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    @AuraEnabled
    public static OrderInvoiceService.SaveResult createDraftInvoice(OrderInvoiceService.SaveRequest request) {
        system.debug('Request>>>>>'+ request);
        try {
            return OrderInvoiceService.createDraftInvoice(request);
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    private static AuraHandledException toAuraHandledException(Exception e) {
        if (e instanceof AuraHandledException) {
            return (AuraHandledException) e;
        }
        return new AuraHandledException(e.getMessage());
    }
    
    @AuraEnabled(cacheable=true)
    public static List<String> getInvoiceStatusValues() {
        try {
            List<String> statusValues = new List<String>();
            Schema.DescribeFieldResult fieldDescribe =
                fax__Invoice__c.fax__Status__c.getDescribe();
    
            for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
                statusValues.add(entry.getValue());
            }
            return statusValues;
    
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getInvoiceClassValues() {
        try {
            List<String> classValues = new List<String>();
            Schema.DescribeFieldResult fieldDescribe =
                fax__Invoice__c.Class__c.getDescribe();
    
            for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
            classValues.add(entry.getValue());
            }
            return classValues;
    
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getInvoiceJobCategoryValues() {
        try {
            List<String> values = new List<String>();
            Schema.DescribeFieldResult fieldDescribe =
                fax__Invoice__c.Job_Category__c.getDescribe();

            for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
                if (entry.isActive()) {
                    values.add(entry.getValue());
                }
            }
            return values;
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getInvoiceTermsValues() {
        try {
            List<String> termsValues = new List<String>();
            Schema.DescribeFieldResult fieldDescribe =
                fax__Invoice__c.fax__Terms__c.getDescribe();

            for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
                termsValues.add(entry.getValue());
            }
            return termsValues;
        } catch (Exception e) {
            throw toAuraHandledException(e);
        }
    }
    @AuraEnabled(cacheable=true)
    public static List<Contact> getAccountContacts(Id accountId) {
        try {
            if (accountId == null) {
                throw new AuraHandledException('Account Id is required.');
            }
    
            return [
                SELECT Id, Name
                FROM Contact
                WHERE AccountId = :accountId
                ORDER BY Name
            ];
    
        } catch (Exception e) {
            throw new AuraHandledException(
                'Failed to load contacts: ' + e.getMessage()
            );
        }
    }
}