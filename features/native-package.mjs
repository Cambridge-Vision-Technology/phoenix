import { Then, setDefaultTimeout } from "@cucumber@";
import { run } from "@steps@";

setDefaultTimeout(@deadline@);
Then("the built native package serves health, UI, a manifest asset and projects in isolated TEST state and stops cleanly", () => run());
