package fixtures

type Cache struct {
	items map[string]string
}

func (cache *Cache) fetch(key string) string {
	return cache.items[key]
}

func load(path string) error {
	_, err := open(path)
	if err != nil {
		if err := rewrite(path); err != nil {
			return err
		}
	}
	return nil
}
