import { Then, setDefaultTimeout } from "@cucumber@";
import { run } from "@steps@";

setDefaultTimeout(@deadline@);
Then("the built native package serves health in isolated TEST state and stops cleanly", () => run());
