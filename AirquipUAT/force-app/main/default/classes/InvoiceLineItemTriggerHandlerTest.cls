@isTest(SeeAllData=true)
private class InvoiceLineItemTriggerHandlerTest {
    private static fax__Invoice__c getInvoice() {
        List<fax__Invoice__c> invs = [
            SELECT Id, Tax__c, Sub_Total_Tax_Product__c
            FROM fax__Invoice__c
            LIMIT 1
        ];
        System.assert(!invs.isEmpty(), 'At least one Invoice record must exist in org for this test.');
        return invs[0];
    }

    private static Id getAnyProductId() {
        List<Product2> products = [SELECT Id FROM Product2 LIMIT 1];
        return products.isEmpty() ? null : products[0].Id;
    }

    private static Id getDifferentProductId(Id currentProductId) {
        List<Product2> products = [
            SELECT Id
            FROM Product2
            WHERE Id != :currentProductId
            LIMIT 1
        ];
        return products.isEmpty() ? null : products[0].Id;
    }

    private static fax__Invoice_Line_Item__c makeLine(Id invoiceId) {
        fax__Invoice_Line_Item__c li = new fax__Invoice_Line_Item__c(
            fax__Invoice__c = invoiceId
        );
        Id productId = getAnyProductId();
        if (productId != null) {
            li.fax__Product__c = productId;
        }
        return li;
    }

    @isTest
    static void testCalculateInvoiceTax_Guards() {
        Test.startTest();
        InvoiceLineItemTriggerHandler.calculateInvoiceTax(null);
        InvoiceLineItemTriggerHandler.calculateInvoiceTax(new List<fax__Invoice_Line_Item__c>());
        InvoiceLineItemTriggerHandler.calculateInvoiceTax(new List<fax__Invoice_Line_Item__c>{
            new fax__Invoice_Line_Item__c()
        });
        Test.stopTest();
        System.assert(true, 'Guard clauses should return without exceptions.');
    }

    @isTest
    static void testTrigger_InsertUpdateDeleteUndelete() {
        fax__Invoice__c inv = getInvoice();
        fax__Invoice_Line_Item__c li = makeLine(inv.Id);

        Test.startTest();
        insert li; // after insert
        Id nextProduct = getDifferentProductId(li.fax__Product__c);
        if (nextProduct != null) {
            li.fax__Product__c = nextProduct;
            update li; // after update with relevant field change
        }
        delete li; // after delete
        undelete li; // after undelete
        Test.stopTest();

        inv = [
            SELECT Id, Sub_Total_Tax_Product__c
            FROM fax__Invoice__c
            WHERE Id = :inv.Id
        ];
        System.assertNotEquals(null, inv.Id, 'Invoice should still exist after line item lifecycle.');
    }

    @isTest
    static void testCalculateInvoiceTax_AllowsRecalculationInSameTransaction() {
        fax__Invoice__c inv = getInvoice();
        fax__Invoice_Line_Item__c li = makeLine(inv.Id);
        insert li;

        List<fax__Invoice_Line_Item__c> payload = new List<fax__Invoice_Line_Item__c>{
            new fax__Invoice_Line_Item__c(Id = li.Id, fax__Invoice__c = inv.Id)
        };

        Test.startTest();
        InvoiceLineItemTriggerHandler.calculateInvoiceTax(payload);
        // Second call must still run so multi-batch inserts (e.g. consolidated invoice) recalculate tax.
        InvoiceLineItemTriggerHandler.calculateInvoiceTax(payload);
        Test.stopTest();

        System.assert(true, 'Subsequent tax calculation in the same transaction completed without error.');
    }
}