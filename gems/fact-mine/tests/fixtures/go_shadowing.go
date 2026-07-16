package fixtures

func load(path string) error {
	_, err := open(path)
	if err != nil {
		if err := rewrite(path); err != nil {
			return err
		}
	}
	return nil
}
