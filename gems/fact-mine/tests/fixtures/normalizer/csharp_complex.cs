class Program {
    static void Main() {
        try {
            throw new System.Exception();
        } catch (System.Exception e) {
            System.Console.WriteLine(e);
        } finally {
        }
        
        var x = cond ? 1 : 2;
    }
}
