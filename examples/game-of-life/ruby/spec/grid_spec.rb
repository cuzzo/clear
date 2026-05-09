require_relative "../grid"

describe "Grid" do
  describe ".survive?" do
    let(:minimum_population) { 2 }
    let(:maximum_population) { 3 }

    subject { survive?(life_state, live_neighbors) }

    context "alive" do
      let(:life_state) { true }

      context "above population maximum" do
        let(:live_neighbors) { maximum_population + 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "below population minimum" do
        let(:live_neighbors) { minimum_population - 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "at population maximum" do
        let(:live_neighbors) { maximum_population }
        it "is true" do
          expect(subject).to eq(true)
        end
      end

      context "at population minimum" do
        let(:live_neighbors) { minimum_population }
        it "is true" do
          expect(subject).to eq(true)
        end
      end

      context "between population minimum / maximum" do
        let(:live_neighbors) { maximum_population - 1 }
        it "is true" do
          expect(subject).to eq(true)
        end
      end
    end

    context "dead" do
      let(:life_state) { false }

      context "above population maximum" do
        let(:live_neighbors) { maximum_population + 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "below population minimum" do
        let(:live_neighbors) { minimum_population - 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "at population maximum" do
        let(:live_neighbors) { maximum_population }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "at population minimum" do
        let(:live_neighbors) { minimum_population }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "between population minimum / maximum" do
        let(:live_neighbors) { maximum_population - 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end
    end
  end

  describe ".revive?" do
    let(:minimum_population) { 3 }
    let(:maximum_population) { 3 }

    subject { revive?(life_state, live_neighbors) }

    context "alive" do
      let(:life_state) { true }

      context "above population maximum" do
        let(:live_neighbors) { maximum_population + 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "below population minimum" do
        let(:live_neighbors) { minimum_population - 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "at population maximum" do
        let(:live_neighbors) { maximum_population }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "at population minimum" do
        let(:live_neighbors) { minimum_population }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "between population minimum / maximum" do
        let(:live_neighbors) { maximum_population - 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end
    end

    context "dead" do
      let(:life_state) { false }

      context "above population maximum" do
        let(:live_neighbors) { maximum_population + 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "below population minimum" do
        let(:live_neighbors) { minimum_population - 1 }
        it "is true" do
          expect(subject).to eq(false)
        end
      end

      context "at population maximum" do
        let(:live_neighbors) { maximum_population }
        it "is true" do
          expect(subject).to eq(true)
        end
      end

      context "at population minimum" do
        let(:live_neighbors) { minimum_population }
        it "is true" do
          expect(subject).to eq(true)
        end
      end

      # TODO: pass rules in...
      context "between population minimum / maximum" do
        let(:live_neighbors) { maximum_population - 1 }
        xit "is true" do
          expect(subject).to eq(false)
        end
      end
    end
  end
end
