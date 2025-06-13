import {initializeMakeSuite} from "./helpers/make-suite";

export default async function setup() {
    before(async () => {
        console.log("-> Initializing test enviroment");
        await initializeMakeSuite();
        console.log("\n***************");
        console.log("Setup and snapshot finished");
        console.log("***************\n");
    });
}
