package main

func main() {
    switch os := runtime.GOOS; os {
    case "darwin":
        fmt.Println("OS X.")
    case "linux":
        fmt.Println("Linux.")
    default:
        fmt.Printf("%s.\n", os)
    }

    for i := 0; i < 10; i++ {
        break
    }
}
