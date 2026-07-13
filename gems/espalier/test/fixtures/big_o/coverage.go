package fixture

type Arm struct{}
type File struct { Arms []Arm }
type Package struct { Files []File }

func walkCoverage(packages []Package) {
	for _, pkg := range packages {
		for _, file := range pkg.Files {
			arms := file.Arms
			for _, arm := range arms {
				consume(arm)
			}
		}
	}
}
