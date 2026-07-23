class NullableCSharp
{
    int Unsafe()
    {
        string value = null;
        return value.Length;
    }

    int Guarded()
    {
        string value = null;
        if (value == null)
        {
            return 0;
        }
        return value.Length;
    }

    int GuardedDisjunction(int flag)
    {
        string value = null;
        if (value == null || flag == 5)
        {
            return 0;
        }
        else
        {
            return value.Length;
        }
    }
}
