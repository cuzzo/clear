int main() {
    int i;
    for (i = 0; i < 10; i++) {
        if (i == 5) continue;
    }
    switch(i) {
        case 1: break;
        default: break;
    }
    return 0;
}
