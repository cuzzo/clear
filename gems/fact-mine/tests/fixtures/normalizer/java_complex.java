class Billing {
    public int mixed(int price, int tax) {
        try {
            return price + tax;
        } catch (Exception e) {
            return 0;
        } finally {
            System.out.println("Done");
        }
    }
    
    public void loops() {
        for (int i = 0; i < 10; i++) {
            if (i % 2 == 0) continue;
        }
        for (String s : new String[]{}) {
        }
        do {
            break;
        } while(false);
    }
}
