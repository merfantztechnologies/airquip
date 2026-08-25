public class InstalledSystemTriggerHandler {

    public static void handleAfterInsertOrUndelete(List<fax__Installed_System__c> newList) {
        syncProductInstalledSystemFlags(collectProductIds(newList));
    }

    public static void handleAfterUpdate(
        List<fax__Installed_System__c> newList,
        Map<Id, fax__Installed_System__c> oldMap
    ) {
        Set<Id> productIds = new Set<Id>();

        for (fax__Installed_System__c installedSystem : newList) {
            fax__Installed_System__c oldInstalledSystem = oldMap.get(installedSystem.Id);

            if (installedSystem.fax__System_Name__c != oldInstalledSystem.fax__System_Name__c) {
                if (installedSystem.fax__System_Name__c != null) {
                    productIds.add(installedSystem.fax__System_Name__c);
                }

                if (oldInstalledSystem.fax__System_Name__c != null) {
                    productIds.add(oldInstalledSystem.fax__System_Name__c);
                }
            }
        }

        syncProductInstalledSystemFlags(productIds);
    }

    public static void handleAfterDelete(List<fax__Installed_System__c> oldList) {
        syncProductInstalledSystemFlags(collectProductIds(oldList));
    }

    private static Set<Id> collectProductIds(List<fax__Installed_System__c> installedSystems) {
        Set<Id> productIds = new Set<Id>();

        for (fax__Installed_System__c installedSystem : installedSystems) {
            if (installedSystem.fax__System_Name__c != null) {
                productIds.add(installedSystem.fax__System_Name__c);
            }
        }

        return productIds;
    }

    private static void syncProductInstalledSystemFlags(Set<Id> productIds) {
        if (productIds == null || productIds.isEmpty()) return;

        Set<Id> productsWithInstalledSystems = new Set<Id>();

        for (AggregateResult result : [
            SELECT fax__System_Name__c productId
            FROM fax__Installed_System__c
            WHERE fax__System_Name__c IN :productIds
            GROUP BY fax__System_Name__c
        ]) {
            productsWithInstalledSystems.add((Id) result.get('productId'));
        }

        List<Product2> productsToUpdate = new List<Product2>();

        for (Product2 product : [
            SELECT Id, Is_Installed_System__c
            FROM Product2
            WHERE Id IN :productIds
        ]) {
            Boolean shouldBeInstalledSystem = productsWithInstalledSystems.contains(product.Id);

            if (product.Is_Installed_System__c != shouldBeInstalledSystem) {
                productsToUpdate.add(new Product2(
                    Id = product.Id,
                    Is_Installed_System__c = shouldBeInstalledSystem
                ));
            }
        }

        if (!productsToUpdate.isEmpty()) {
            update productsToUpdate;
        }
    }
}