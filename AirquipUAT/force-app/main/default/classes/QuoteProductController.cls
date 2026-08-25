public with sharing class QuoteProductController {

    public Id quoteId {get; set;}
    public Integer stepNumber {get; set;}

    public String searchKey {get; set;}
    public Integer pageSize = 50;
    public Integer offsetSize = 0;

    public List<ProductWrapper> products {get; set;}
    public Map<Id, ProductWrapper> selectedMap {get; set;}
    public List<ProductWrapper> selectedProducts {get; set;}

    public QuoteProductController() {
        quoteId = ApexPages.currentPage().getParameters().get('id');
        stepNumber = 1;
        selectedMap = new Map<Id, ProductWrapper>();
        loadProducts();
    }

    // 🔍 Load Products
    public void loadProducts() {
        products = new List<ProductWrapper>();

        String query = 'SELECT Id, Product2.Name, UnitPrice, Cost__c ' +
                       'FROM PricebookEntry WHERE IsActive = true';

        if(String.isNotBlank(searchKey)) {
            query += ' AND Product2.Name LIKE \'%' + searchKey + '%\'';
        }

        query += ' LIMIT :pageSize OFFSET :offsetSize';

        List<PricebookEntry> pbeList = Database.query(query);

        for (PricebookEntry pbe : pbeList) {
            ProductWrapper pw = new ProductWrapper(pbe);

            // maintain selection
            if(selectedMap.containsKey(pbe.Id)) {
                pw.isSelected = true;
            }

            products.add(pw);
        }
    }

    // 🔍 Search
    public void search() {
        offsetSize = 0;
        loadProducts();
    }

    // ➡ Next Page
    public void nextPage() {
        offsetSize += pageSize;
        loadProducts();
    }

    // ⬅ Previous Page
    public void prevPage() {
        offsetSize = Math.max(0, offsetSize - pageSize);
        loadProducts();
    }

    // ➡ Move to Step 2
    public void nextStep() {
        for(ProductWrapper pw : products) {
            if(pw.isSelected) {
                selectedMap.put(pw.pbeId, pw);
            } else {
                selectedMap.remove(pw.pbeId);
            }
        }

        selectedProducts = selectedMap.values();
        stepNumber = 2;
    }

    // ⬅ Back
    public void backStep() {
        stepNumber = 1;
        loadProducts();
    }

    // 💾 Save
    public PageReference save() {
        List<QuoteLineItem> qlis = new List<QuoteLineItem>();

        for(ProductWrapper pw : selectedProducts) {
            qlis.add(new QuoteLineItem(
                QuoteId = quoteId,
                PricebookEntryId = pw.pbeId,
                Quantity = pw.quantity,
                UnitPrice = pw.salesPrice,
                Cost__c = pw.cost
            ));
        }

        insert qlis;

        return new PageReference('/' + quoteId);
    }

    // Wrapper
    public class ProductWrapper {
        public Id pbeId {get; set;}
        public String name {get; set;}
        public Decimal listPrice {get; set;}
        public Decimal cost {get; set;}
        public Decimal salesPrice {get; set;}
        public Decimal quantity {get; set;}
        public Boolean isSelected {get; set;}

        public ProductWrapper(PricebookEntry pbe) {
            this.pbeId = pbe.Id;
            this.name = pbe.Product2.Name;
            this.listPrice = pbe.UnitPrice;
            this.cost = pbe.Cost__c;
            this.salesPrice = pbe.UnitPrice;
            this.quantity = 1;
            this.isSelected = false;
        }
    }
}