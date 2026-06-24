def complex_try():
    try:
        1 / 0
    except ZeroDivisionError as e:
        print(e)
    except Exception:
        print("Error")
    else:
        print("Success")
    finally:
        print("Cleanup")

def list_comp():
    return [x for x in range(10) if x % 2 == 0]

@decorator
def decorated():
    pass

class A:
    pass
